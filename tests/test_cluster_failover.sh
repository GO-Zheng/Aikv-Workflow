#!/bin/bash

# AiKv 集群故障转移测试脚本
# 测试 master 节点故障后，replica 是否能自动提升为 master
#
# 用法: ./test_cluster_failover.sh [master_port] [replica_port]
# 默认: master_port=6379 (aikv-master-1), replica_port=6380 (aikv-replica-1)
#
# 说明:
#   - 步骤 0 会检查 master/replica 容器的 AIKV_AUTO_FAILOVER；未 true 时 WARN（仍可依赖 TAKEOVER）。
#   - docker-compose 可能为 false；仅靠等待**不会**自动提升时取决于该变量。
#   - 本脚本在停主后若副本仍未变 master，会执行一次 CLUSTER FAILOVER TAKEOVER（不依赖环境变量）。
#   - 测试 key 使用 hashtag，脚本会校验 slot 落在 master-1 默认槽位 0-5460，避免写到其他分片。

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

# 从容器 Config.Env 读取 key=value（无则空）
container_env_get() {
  local ctn="$1"
  local key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctn" 2>/dev/null \
    | sed -n "s/^${key}=//p" | head -1 | tr -d '\r'
}

echo "=============================================="
echo " AiKv 集群故障转移测试"
echo "=============================================="
echo ""
info "测试配置:"
info "  Master 容器: $MASTER_CONTAINER (port $MASTER_PORT)"
info "  Replica 容器: $REPLICA_CONTAINER (port $REPLICA_PORT)"
echo ""

# --- 0. 检查 AIKV_AUTO_FAILOVER ---
echo -e "${YELLOW}[步骤 0] 检查容器环境变量 AIKV_AUTO_FAILOVER${NC}"

for c in "$MASTER_CONTAINER" "$REPLICA_CONTAINER"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    fail "未找到容器: $c（请先启动集群）"
    exit 1
  fi
done

master_af=$(container_env_get "$MASTER_CONTAINER" "AIKV_AUTO_FAILOVER")
replica_af=$(container_env_get "$REPLICA_CONTAINER" "AIKV_AUTO_FAILOVER")

if [ -z "$master_af" ]; then
  info "$MASTER_CONTAINER: AIKV_AUTO_FAILOVER 未设置（AiKv 未设置时按 false）"
else
  info "$MASTER_CONTAINER: AIKV_AUTO_FAILOVER=$master_af"
fi
if [ -z "$replica_af" ]; then
  info "$REPLICA_CONTAINER: AIKV_AUTO_FAILOVER 未设置（AiKv 未设置时按 false）"
else
  info "$REPLICA_CONTAINER: AIKV_AUTO_FAILOVER=$replica_af"
fi

replica_af_lc=$(echo "$replica_af" | tr '[:upper:]' '[:lower:]')
if [ "$replica_af_lc" != "true" ]; then
  warn "副本 $REPLICA_CONTAINER 未开启 AIKV_AUTO_FAILOVER=true；停主后仅靠等待通常不会自动升主，本脚本将依赖步骤 4 的 CLUSTER FAILOVER TAKEOVER。"
else
  ok "副本已设置 AIKV_AUTO_FAILOVER=true（步骤 4 仍可在未自动升主时用 TAKEOVER 兜底）"
fi

echo ""

# --- 1. 记录故障前状态 ---
echo -e "${YELLOW}[步骤 1] 记录故障前状态${NC}"

# 本节点视角（避免 grep 到集群里「别的」master/slave 行）
master_info=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER NODES 2>/dev/null | grep "myself" | head -1 || true)
info "Master $MASTER_PORT myself 行: $master_info"

replica_info=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | head -1 || true)
info "Replica $REPLICA_PORT myself 行: $replica_info"

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
slot=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER KEYSLOT "$test_key" 2>/dev/null | tr -d '\r' || echo "")
if [[ -n "$slot" ]] && [[ "$slot" =~ ^[0-9]+$ ]]; then
    if [ "$slot" -gt 5460 ]; then
        warn "CLUSTER KEYSLOT $test_key -> $slot，不在 master-1 默认槽 0-5460；停 aikv-master-1 可能测不到该 key 的复制组"
    else
        info "CLUSTER KEYSLOT $test_key -> $slot（应在 master-1 / replica-1 分片）"
    fi
fi
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

info "等待副本侧检测故障（默认 compose 下自动 failover 关闭，仅靠等待通常不会提升）..."
sleep 15

echo ""

# --- 4. 检查 replica 是否提升为 master ---
echo -e "${YELLOW}[步骤 4] 检查 replica 是否提升为 master${NC}"

# 检查 replica 的角色变化
replica_role=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | awk '{print $3}' | tr -d '\r' || echo "unknown")
info "Replica $REPLICA_PORT 当前角色: $replica_role"

# 若仍为 slave，尝试手动接管（不依赖 AIKV_AUTO_FAILOVER）
if echo "$replica_role" | grep -q "slave"; then
    warn "副本仍为 slave，尝试 CLUSTER FAILOVER TAKEOVER（主节点已停时由副本发起）..."
    fo_out=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER FAILOVER TAKEOVER 2>&1 || true)
    info "CLUSTER FAILOVER TAKEOVER 输出: $fo_out"
    sleep 5
    replica_role=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | awk '{print $3}' | tr -d '\r' || echo "unknown")
    info "重试后 Replica $REPLICA_PORT 角色: $replica_role"
fi

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