#!/bin/bash

# AiKv 集群故障转移测试脚本
# 测试 master 节点故障后，replica 是否能自动提升为 master
#
# 用法: ./test_failover.sh [master_port] [replica_port]
# 默认: master_port=6379 (aikv-master-1), replica_port=6382 (aikv-replica-1)

set -e

MASTER_PORT="${1:-6379}"
REPLICA_PORT="${2:-6380}"
MASTER_CONTAINER="aikv-master-1"
REPLICA_CONTAINER="aikv-replica-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=============================================="
echo " AiKv 集群故障转移测试"
echo "=============================================="
echo ""
info "测试配置:"
info "  Master 容器: $MASTER_CONTAINER (port $MASTER_PORT)"
info "  Replica 容器: $REPLICA_CONTAINER (port $REPLICA_PORT)"
echo ""

# --- 1. 记录故障前状态 ---
echo -e "${YELLOW}[步骤 1] 记录故障前状态${NC}"

# 检查 master 当前状态
master_info=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER NODES 2>/dev/null | grep "master" | head -1)
info "Master $MASTER_PORT 状态: $master_info"

# 检查 replica 当前状态
replica_info=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "slave" | head -1)
info "Replica $REPLICA_PORT 状态: $replica_info"

# 查找 replica 对应的 master
replica_master_id=$(echo "$replica_info" | awk '{print $4}' | tr -d '\r')
info "Replica 的 master ID: $replica_master_id"

# 检查 MetaRaft 投票者/学习者状态
echo -e "${BLUE}[步骤 1.5] MetaRaft 投票者/学习者状态${NC}"
info "检查 $MASTER_PORT 的 MetaRaft 成员状态..."
redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER METARAFT MEMBERS 2>/dev/null || warn "无法获取 MetaRaft 成员状态"
info "检查 $REPLICA_PORT 的 MetaRaft 成员状态..."
redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER METARAFT MEMBERS 2>/dev/null || warn "无法获取 MetaRaft 成员状态"

echo ""

# --- 2. 写入测试数据 ---
echo -e "${YELLOW}[步骤 2] 写入测试数据${NC}"

test_key="{failover_test}:data"
test_value="test_$(date +%s)"
redis-cli -c -h 127.0.0.1 -p $MASTER_PORT SET "$test_key" "$test_value" >/dev/null 2>&1
info "写入测试数据: $test_key = $test_value"

# 确认写入成功
written_value=$(redis-cli -c -h 127.0.0.1 -p $MASTER_PORT GET "$test_key" 2>/dev/null)
if [ "$written_value" = "$test_value" ]; then
    ok "数据写入成功"
else
    fail "数据写入失败"
    exit 1
fi

echo ""

# --- 3. 模拟 master 故障 ---
echo -e "${YELLOW}[步骤 3] 模拟 master 故障 (停止容器)${NC}"

info "正在停止容器: $MASTER_CONTAINER..."
docker stop $MASTER_CONTAINER >/dev/null 2>&1
ok "容器已停止"

info "等待集群检测故障并触发 failover (15秒)..."
sleep 15

echo ""

# --- 4. 检查 replica 是否提升为 master ---
echo -e "${YELLOW}[步骤 4] 检查 replica 是否提升为 master${NC}"

# 检查 replica 的角色变化
replica_role=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | awk '{print $3}' | tr -d '\r' || echo "unknown")
info "Replica $REPLICA_PORT 当前角色: $replica_role"

# 检查集群状态
cluster_info=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER INFO 2>/dev/null)
cluster_state=$(echo "$cluster_info" | grep "cluster_state" | cut -d: -f2 | tr -d '\r')
cluster_slots_assigned=$(echo "$cluster_info" | grep "cluster_slots_assigned" | cut -d: -f2 | tr -d '\r')
info "集群状态: $cluster_state"
info "已分配 slots: $cluster_slots_assigned"

# 检查 replica 是否接管了原来 master 的 slots
replica_slots=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | awk '{print $9}' | tr -d '\r' || echo "")
info "Replica 接管 slots: ${replica_slots:-无}"

# 检查 MetaRaft 投票者/学习者状态（故障后）
echo -e "${BLUE}[步骤 4.5] MetaRaft 投票者/学习者状态（故障后）${NC}"
info "检查 $REPLICA_PORT 的 MetaRaft 成员状态..."
redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER METARAFT MEMBERS 2>/dev/null || warn "无法获取 MetaRaft 成员状态"

echo ""

# --- 5. 验证数据完整性 ---
echo -e "${YELLOW}[步骤 5] 验证数据完整性${NC}"

# 尝试读取测试数据（通过集群模式）
read_value=$(redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT GET "$test_key" 2>/dev/null || echo "ERROR")
if [ "$read_value" = "$test_value" ]; then
    ok "数据完整性验证通过: $test_key = $read_value"
elif [ "$read_value" = "ERROR" ]; then
    warn "无法读取测试数据（slot 可能已迁移）"
else
    warn "数据不一致: 期望 $test_value, 实际 $read_value"
fi

echo ""

# --- 6. 恢复 master ---
echo -e "${YELLOW}[步骤 6] 恢复故障的 master 节点${NC}"

info "正在启动容器: $MASTER_CONTAINER..."
docker start $MASTER_CONTAINER >/dev/null 2>&1
ok "容器已启动"

info "等待节点就绪 (10秒)..."
sleep 10

# 检查恢复后的 master 状态
master_after=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER NODES 2>/dev/null | grep "myself" || echo "not ready")
if echo "$master_after" | grep -q "master"; then
    ok "Master 节点恢复完成"
else
    warn "Master 节点尚未完全恢复"
fi

echo ""

# --- 总结 ---
echo "=============================================="
echo -e "${GREEN}[测试完成]${NC}"
echo "=============================================="
echo ""
echo "故障转移测试摘要:"
echo "  - Master 故障: $MASTER_CONTAINER 已停止"
echo "  - Replica 提升: $REPLICA_PORT 状态已检查"
echo "  - 集群状态: $cluster_state"
echo "  - Slots 分配: $cluster_slots_assigned"
echo ""
echo "如需查看详细信息:"
echo "  redis-cli -p $REPLICA_PORT CLUSTER INFO"
echo "  redis-cli -p $REPLICA_PORT CLUSTER NODES"
echo ""

# --- 清理测试数据 ---
info "清理测试数据..."
redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT DEL "$test_key" >/dev/null 2>&1 || true
ok "测试数据已清理"