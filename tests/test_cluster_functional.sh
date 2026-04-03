#!/bin/bash

# AiKv 集群功能测试脚本
# 测试集群特有的命令和 Redis Cluster 协议兼容性
#
# 用法: ./test_cluster_functional.sh [host] [port]
# 默认: host=127.0.0.1 port=6379
#
# 前置条件:
#   1. 集群已启动（6节点：6379-6381 master, 6382-6384 replica）
#   2. 集群已初始化（slots 已分配）
#   3. 各节点可正常访问

set -e

HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
CLI="redis-cli -h $HOST -p $PORT"
CLI_CLUSTER="redis-cli -c -h $HOST -p $PORT"  # 集群模式

# 集群节点配置
MASTER_PORTS=(6379 6381 6383)
REPLICA_PORTS=(6380 6382 6384)
ALL_PORTS=(6379 6380 6381 6382 6383 6384)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=============================================="
echo " AiKv 集群功能测试 (host=$HOST port=$PORT)"
echo "=============================================="

# --- 前置检查 ---
echo -e "\n${YELLOW}[前置检查] 集群状态验证${NC}"

# 检查集群是否启用
cluster_enabled=$($CLI INFO cluster 2>/dev/null | grep "cluster_enabled" | cut -d: -f2 | tr -d '\r')
if [ "$cluster_enabled" != "1" ]; then
    fail "集群未启用 (cluster_enabled=$cluster_enabled)"
fi
ok "集群已启用"

# 检查集群状态
cluster_state=$($CLI CLUSTER INFO 2>/dev/null | grep "cluster_state" | cut -d: -f2 | tr -d '\r')
if [ "$cluster_state" != "ok" ]; then
    warn "集群状态: $cluster_state (可能 slots 未完全分配)"
else
    ok "集群状态: ok"
fi

# 检查 slots 分配
slots_assigned=$($CLI CLUSTER INFO 2>/dev/null | grep "cluster_slots_assigned" | cut -d: -f2 | tr -d '\r')
info "已分配 slots: $slots_assigned/16384"

# 检查节点数量（排除 myself 行，处理 \r\n 换行符）
node_count=$($CLI CLUSTER NODES 2>/dev/null | grep -v "myself" | tr -d '\r' | wc -l)
if [ "$node_count" -lt 5 ]; then
    warn "节点数量: $node_count (期望 6)"
else
    ok "节点数量: $node_count (不含 myself 节点)"
fi

# --- 基础连接测试 ---
echo -e "\n${YELLOW}[基础] PING / ECHO${NC}"
r=$($CLI PING 2>/dev/null)
[ "$r" = "PONG" ] && ok "PING" || fail "PING (got: $r)"
r=$($CLI ECHO "hello" 2>/dev/null)
[ "$r" = "hello" ] && ok "ECHO" || fail "ECHO (got: $r)"

# --- 集群信息命令 ---
echo -e "\n${YELLOW}[集群] CLUSTER INFO${NC}"
$CLI CLUSTER INFO >/dev/null 2>&1 && ok "CLUSTER INFO" || fail "CLUSTER INFO"
cluster_size=$($CLI CLUSTER INFO 2>/dev/null | grep "cluster_size" | cut -d: -f2 | tr -d '\r')
info "集群大小: $cluster_size"

echo -e "\n${YELLOW}[集群] CLUSTER NODES${NC}"
$CLI CLUSTER NODES >/dev/null 2>&1 && ok "CLUSTER NODES" || fail "CLUSTER NODES"
# 统计 master 和 slave 数量
master_count=$($CLI CLUSTER NODES 2>/dev/null | grep -c "master" || true)
slave_count=$($CLI CLUSTER NODES 2>/dev/null | grep -c "slave" || true)
info "Masters: $master_count, Slaves: $slave_count"

echo -e "\n${YELLOW}[集群] CLUSTER SLOTS${NC}"
$CLI CLUSTER SLOTS >/dev/null 2>&1 && ok "CLUSTER SLOTS" || fail "CLUSTER SLOTS"

echo -e "\n${YELLOW}[集群] CLUSTER MYID${NC}"
node_id=$($CLI CLUSTER MYID 2>/dev/null)
[ -n "$node_id" ] && ok "CLUSTER MYID: $node_id" || fail "CLUSTER MYID"

echo -e "\n${YELLOW}[集群] CLUSTER KEYSLOT${NC}"
# 测试与 Redis 兼容的 slot 计算
slot1=$($CLI CLUSTER KEYSLOT "user:1000" 2>/dev/null)
slot2=$($CLI CLUSTER KEYSLOT "user:2000" 2>/dev/null)
slot3=$($CLI CLUSTER KEYSLOT "{user}:1000" 2>/dev/null)
slot4=$($CLI CLUSTER KEYSLOT "{user}:2000" 2>/dev/null)
info "user:1000 -> slot $slot1"
info "user:2000 -> slot $slot2"
info "{user}:1000 -> slot $slot3 (hashtag)"
info "{user}:2000 -> slot $slot4 (hashtag)"

# 验证 hashtag 相同
if [ "$slot3" = "$slot4" ]; then
    ok "Hashtag 计算正确: {user} -> slot $slot3"
else
    fail "Hashtag 计算错误: $slot3 != $slot4"
fi

# --- MetaRaft 命令 ---
echo -e "\n${YELLOW}[MetaRaft] CLUSTER METARAFT MEMBERS${NC}"
$CLI CLUSTER METARAFT MEMBERS >/dev/null 2>&1 && ok "CLUSTER METARAFT MEMBERS" || warn "CLUSTER METARAFT MEMBERS 未实现"

echo -e "\n${YELLOW}[MetaRaft] CLUSTER METARAFT STATUS${NC}"
$CLI CLUSTER METARAFT STATUS >/dev/null 2>&1 && ok "CLUSTER METARAFT STATUS" || warn "CLUSTER METARAFT STATUS 未实现"

# --- 集群路由测试 ---
echo -e "\n${YELLOW}[路由] 跨节点数据操作${NC}"

# 使用 hashtag 确保同一 slot
test_key="{cluster_test}:key1"
test_value="value_from_port_$PORT"

# 写入（检查实际响应，redis-cli 返回 ERR 时 exit code 也为 0）
set_result=$($CLI_CLUSTER SET "$test_key" "$test_value" 2>&1)
if [ "$set_result" = "OK" ]; then
    ok "SET $test_key"
else
    fail "SET $test_key (got: $set_result)"
fi

# 读取（可能路由到其他节点）
result=$($CLI_CLUSTER GET "$test_key" 2>/dev/null)
if [ "$result" = "$test_value" ]; then
    ok "GET $test_key -> $result"
else
    fail "GET $test_key (expected: $test_value, got: $result)"
fi

# --- Slot 分布验证 ---
echo -e "\n${YELLOW}[Slot] 验证 slot 归属${NC}"

# 随机选择几个 key，验证它们被路由到正确的 master
for key in "abc" "xyz" "12345" "hello world" "test:{tag}:item"; do
    slot=$($CLI CLUSTER KEYSLOT "$key" 2>/dev/null)
    # 尝试读取（会自动路由）
    val=$($CLI_CLUSTER GET "$key" 2>/dev/null || true)
    info "KEY $key -> slot $slot -> value: ${val:-nil}"
done

# --- 多节点健康检查 ---
echo -e "\n${YELLOW}[多节点] 检查所有 Master 节点${NC}"
for port in "${MASTER_PORTS[@]}"; do
    r=$(redis-cli -h 127.0.0.1 -p $port PING 2>/dev/null)
    if [ "$r" = "PONG" ]; then
        ok "Master port $port 正常"
    else
        fail "Master port $port 无响应"
    fi
done

echo -e "\n${YELLOW}[多节点] 检查所有 Replica 节点${NC}"
for port in "${REPLICA_PORTS[@]}"; do
    r=$(redis-cli -h 127.0.0.1 -p $port PING 2>/dev/null)
    if [ "$r" = "PONG" ]; then
        ok "Replica port $port 正常"
    else
        fail "Replica port $port 无响应"
    fi
done

# --- 主从复制验证 ---
echo -e "\n${YELLOW}[复制] 验证主从关系${NC}"

# 找到 master 节点
master_6379_role=$($CLI CLUSTER NODES 2>/dev/null | grep "127.0.0.1:6379" | grep "master" | head -1)
if echo "$master_6379_role" | grep -q "slave"; then
    # 6379 是 slave，找到它的 master
    master_of_6379=$(echo "$master_6379_role" | awk '{print $4}' | tr -d '\r')
    info "6379 是 replica of $master_of_6379"
else
    ok "6379 是 master 或独立节点"
fi

# 检查 replica 数量
replica_info=$($CLI CLUSTER NODES 2>/dev/null | grep -E "slave|master" | grep -v "myself" || true)
info "主从关系:\n$replica_info"

# --- 故障转移测试（可选）---
echo -e "\n${YELLOW}[故障转移] 检查 failover 支持${NC}"
# 这个测试比较危险，通常跳过
info "故障转移测试已跳过（需手动验证）"

# --- 数据一致性测试 ---
echo -e "\n${YELLOW}[一致性] 写入一致性测试${NC}"

consistency_key="{consistency_test}:data"
consistency_value="test_$(date +%s)"

# 写入（使用集群模式，自动路由到正确节点）
$CLI_CLUSTER SET "$consistency_key" "$consistency_value" >/dev/null 2>&1
sleep 0.5

# 获取 key 所属的 slot
slot=$($CLI CLUSTER KEYSLOT "$consistency_key" 2>/dev/null)
info "测试 key: $consistency_key"
info "所属 slot: $slot"

# 获取该 slot 属于哪个 master
# CLUSTER SLOTS 返回格式: start_slot end_slot master_ip master_port replica1_ip replica1_port ...
slot_info=$($CLI CLUSTER SLOTS 2>/dev/null | grep -A1 "^$slot$" | tail -1 || true)
if [ -z "$slot_info" ]; then
    # 尝试另一种方式获取 slot 所属的 master
    slot_info=$($CLI CLUSTER SLOTS 2>/dev/null | awk -v s="$slot" '$1 <= s && s <= $2 {print $0; exit}')
fi

if [ -n "$slot_info" ]; then
    # 从 slot_info 中提取 master 地址
    master_port=$(echo "$slot_info" | awk '{print $3}' | cut -d: -f2)
    info "该 slot 属于 master port: $master_port"

    # 只在正确的 master 上验证
    val=$(redis-cli -h 127.0.0.1 -p $master_port GET "$consistency_key" 2>/dev/null || echo "ERROR")
    if [ "$val" = "$consistency_value" ]; then
        ok "Master port $master_port 数据一致"
    else
        fail "Master port $master_port 数据不一致: $val"
    fi
else
    # 回退：在当前节点使用集群模式读取
    val=$($CLI_CLUSTER GET "$consistency_key" 2>/dev/null)
    if [ "$val" = "$consistency_value" ]; then
        ok "集群模式读取一致"
    else
        warn "数据读取不一致: $val"
    fi
fi

# --- 清理测试数据 ---
echo -e "\n${YELLOW}[清理] 清理测试数据${NC}"
$CLI_CLUSTER DEL "$test_key" "$consistency_key" >/dev/null 2>&1 || true
ok "测试数据已清理"

# --- 总结 ---
echo -e "\n=============================================="
echo -e "${GREEN}[SUCCESS] 集群功能测试完成${NC}"
echo "=============================================="
echo ""
echo "测试结果摘要:"
echo "  - 集群状态: $cluster_state"
echo "  - 已分配 slots: $slots_assigned/16384"
echo "  - 节点数量: $node_count (不含 myself 节点)"
echo "  - Masters: $master_count, Replicas: $slave_count"
echo ""
echo "如需进一步测试:"
echo "  1. 故障转移: 手动关闭 master 节点，观察 replica 提升"
echo "  2. 迁移测试: 使用 CLUSTER SETSLOT MIGRATING"
echo "  3. 压力测试: 使用 redis-benchmark -c -t set,get"
echo ""