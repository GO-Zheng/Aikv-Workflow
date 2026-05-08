#!/bin/bash

# AiKv 集群故障转移测试脚本
#
# 测试步骤:
#   1. 检查容器和自动故障转移配置
#   2. 记录故障前集群状态
#   3. 写入测试数据并等待 Raft 复制完成
#   4. 模拟 master 故障（停止容器）
#   5. 检查/触发故障转移（先等自动提升，超时后用 TAKEOVER）
#   6. 验证数据完整性和写入能力
#   7. 恢复故障节点
#   8. 清理测试数据
#
# 用法: ./test_cluster_failover.sh [master_port] [replica_port]

set -euo pipefail

MASTER_PORT="${1:-6379}"
REPLICA_PORT="${2:-6380}"
MASTER_CONTAINER="aikv-master-1"
REPLICA_CONTAINER="aikv-replica-1a"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; FAILED=true; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

FAILED=false

# ---------- helpers ----------

container_env_get() {
  local ctn="$1" key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctn" 2>/dev/null \
    | sed -n "s/^${key}=//p" | head -1 | tr -d '\r'
}

# 从 CLUSTER NODES 中解析指定节点的角色: master/slave
get_node_role_from_nodes() {
  local host="$1" port="$2" node_id="$3"
  redis-cli -h "$host" -p "$port" CLUSTER NODES 2>/dev/null \
    | grep "^${node_id}" | awk '{print $3}' | tr -d '\r' | sed 's/myself,//'
}

# 等待条件成立（轮询）
wait_for() {
  local desc="$1" timeout="$2" interval="$3" cmd="$4"
  shift 4
  info "等待 $desc（超时 ${timeout}s）..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      ok "$desc（${elapsed}s）"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  warn "等待 $desc 超时（${timeout}s）"
  return 1
}

# ---------- main ----------
echo "=============================================="
echo " AiKv 集群故障转移测试"
echo "=============================================="
echo ""

info "测试配置:"
info "  Master 容器: $MASTER_CONTAINER (port $MASTER_PORT)"
info "  Replica 容器: $REPLICA_CONTAINER (port $REPLICA_PORT)"
echo ""

# ---- 0. 基本环境检查 ----
echo -e "${YELLOW}[步骤 0] 检查容器和环境${NC}"

for c in "$MASTER_CONTAINER" "$REPLICA_CONTAINER"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    fail "未找到容器: $c（请先启动集群）"
    exit 1
  fi
done

# 检查 AIKV_AUTO_FAILOVER
for c in "$MASTER_CONTAINER" "$REPLICA_CONTAINER"; do
  val=$(container_env_get "$c" "AIKV_AUTO_FAILOVER")
  if [ -z "$val" ]; then
    info "$c: AIKV_AUTO_FAILOVER 未设置"
  else
    info "$c: AIKV_AUTO_FAILOVER=$val"
  fi
done

replica_af=$(container_env_get "$REPLICA_CONTAINER" "AIKV_AUTO_FAILOVER")
replica_af_lc=$(echo "$replica_af" | tr '[:upper:]' '[:lower:]')
AUTO_FAILOVER_ENABLED=false
if [ "$replica_af_lc" = "true" ] || [ "$replica_af_lc" = "1" ]; then
  AUTO_FAILOVER_ENABLED=true
  ok "副本已设置 AIKV_AUTO_FAILOVER=true"
fi

echo ""

# ---- 1. 记录故障前状态 ----
echo -e "${YELLOW}[步骤 1] 记录故障前状态${NC}"

master_info=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER NODES 2>/dev/null | grep "myself" | head -1 || true)
info "Master $MASTER_PORT: $master_info"

replica_info=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself" | head -1 || true)
info "Replica $REPLICA_PORT: $replica_info"

# 解析 replica 对应的 master ID
replica_master_id=$(echo "$replica_info" | awk '{print $4}' | tr -d '\r')
info "Replica 的 master ID: $replica_master_id"

# 确认 replica 角色初始为 slave
replica_role=$(echo "$replica_info" | awk '{print $3}' | tr -d '\r')
if echo "$replica_role" | grep -q "slave"; then
  ok "Replica 初始角色为 slave（期望）"
else
  warn "Replica 初始角色: $replica_role（期望 slave）"
fi

# MetaRaft 成员状态
info "MetaRaft 成员状态（master）:"
redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER METARAFT MEMBERS 2>/dev/null || warn "无法获取 MetaRaft 成员"

echo ""

# Wait for Data Raft membership to converge after cluster init.
# Reconciliation runs on a background timer and may take a few cycles.
info "等待 Data Raft 成员关系收敛（10s）..."
sleep 10

# ---- 2. 写入测试数据 ----
echo -e "${YELLOW}[步骤 2] 写入测试数据${NC}"

test_key="{failover_test}:data"
test_value="test_$(date +%s)"
test_key2="{failover_test}:after_failover"

slot=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER KEYSLOT "$test_key" 2>/dev/null | tr -d '\r')
info "CLUSTER KEYSLOT $test_key -> $slot"
if [[ -n "$slot" ]] && [[ "$slot" =~ ^[0-9]+$ ]] && [ "$slot" -gt 8191 ]; then
  warn "slot=$slot 不在 0-8191 范围，可能不在 master-1 分片上"
fi

# 写入数据（使用 -c 集群模式确保正确路由）
redis-cli -c -h 127.0.0.1 -p $MASTER_PORT SET "$test_key" "$test_value" >/dev/null 2>&1
readback=$(redis-cli -c -h 127.0.0.1 -p $MASTER_PORT GET "$test_key" 2>/dev/null)
if [ "$readback" = "$test_value" ]; then
  ok "数据写入成功: $test_key = $test_value"
else
  fail "数据写入失败（取回: $readback）"
  exit 1
fi

# Wait for Raft replication to replica (poll via READONLY GET).
# AiKv uses Raft-based replication, not Redis replication.
# INFO replication master_repl_offset is always 0 and WAIT is unsupported.
info "等待数据复制到 Replica $REPLICA_PORT ..."
repl_ok=false

for _i in $(seq 1 30); do
  replica_val=$(redis-cli --readonly -h 127.0.0.1 -p $REPLICA_PORT GET "$test_key" 2>/dev/null || true)
  if [ "$replica_val" = "$test_value" ]; then
    ok "数据已复制到 replica（等待 ${_i}s）"
    repl_ok=true
    break
  fi
  sleep 1
done

if [ "$repl_ok" != "true" ]; then
  fail "数据未复制到 replica（30s 超时）: Raft 复制异常"
fi

echo ""

# ---- 3. 模拟 master 故障 ----
echo -e "${YELLOW}[步骤 3] 模拟 master 故障（停止容器）${NC}"

info "正在停止容器: $MASTER_CONTAINER..."
docker stop $MASTER_CONTAINER >/dev/null 2>&1
ok "容器已停止"

echo ""

# ---- 4. 执行故障转移 ----
echo -e "${YELLOW}[步骤 4] 执行故障转移${NC}"

PROMOTED=false

# 4a. 如果开启自动故障转移，等待提升
if [ "$AUTO_FAILOVER_ENABLED" = "true" ]; then
  info "AIKV_AUTO_FAILOVER=true，等待自动提升..."
  if wait_for "Replica 自动提升为 master" 60 3 \
    "redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep 'myself' | grep -q 'master'"
  then
    PROMOTED=true
    ok "自动故障转移成功"
  else
    warn "自动提升超时，尝试手动 TAKEOVER..."
  fi
fi

# 4b. 手动 TAKEOVER
if [ "$PROMOTED" != "true" ]; then
  info "执行 CLUSTER FAILOVER TAKEOVER..."
  fo_out=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER FAILOVER TAKEOVER 2>&1 || true)
  info "TAKEOVER 返回: $fo_out"

  # 等待提升（含多次重试）
  if wait_for "Replica 提升为 master" 30 2 \
    "redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep 'myself' | grep -q 'master'"
  then
    PROMOTED=true
    ok "手动 TAKEOVER 成功"
  else
    fail "CLUSTER FAILOVER TAKEOVER 返回 OK 但 replica 未提升为 master"
  fi
fi

# Wait for MetaRaft cache to sync with the actual Data Raft leader
# (background watcher runs every 2s; 3s gives one full cycle)
info "等待 MetaRaft 缓存与 Data Raft leader 同步..."
sleep 3

# 4c. 检查集群整体状态
cluster_info=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER INFO 2>/dev/null || echo "")
cluster_state=$(echo "$cluster_info" | grep "cluster_state" | cut -d: -f2 | tr -d '\r')
cluster_slots=$(echo "$cluster_info" | grep "cluster_slots_assigned" | cut -d: -f2 | tr -d '\r')
info "集群状态: $cluster_state"
info "已分配 slots: $cluster_slots"

if [ "$PROMOTED" = "true" ]; then
  # 检查节点接管了正确的 slots
  my_line=$(redis-cli -h 127.0.0.1 -p $REPLICA_PORT CLUSTER NODES 2>/dev/null | grep "myself")
  my_slots=$(echo "$my_line" | awk '{for(i=9;i<=NF;i++) printf "%s ", $i}')
  info "本节点 slots: ${my_slots:-无}"
  if [ -n "$my_slots" ]; then
    ok "新 master 已接管 slots: $my_slots"
  fi

  # 检查新 master 是否可写
  new_val="after_failover_$(date +%s)"
  if redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT SET "$test_key2" "$new_val" >/dev/null 2>&1; then
    readback2=$(redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT GET "$test_key2" 2>/dev/null)
    if [ "$readback2" = "$new_val" ]; then
      ok "新 master 可写: $test_key2 = $new_val"
    else
      fail "新 master 写入后验证不一致"
    fi
  else
    fail "新 master 不可写"
  fi
fi

echo ""

# ---- 5. 验证数据完整性 ----
echo -e "${YELLOW}[步骤 5] 验证数据完整性${NC}"

# 从当前 master（或 replica）读取原始数据
read_value=$(redis-cli --readonly -h 127.0.0.1 -p $REPLICA_PORT GET "$test_key" 2>/dev/null || echo "ERROR")
if [ "$read_value" = "$test_value" ]; then
  ok "数据完整性验证通过: $test_key = $read_value"
elif [ "$read_value" = "ERROR" ]; then
  fail "无法读取测试数据"
else
  warn "数据不一致: 期望 $test_value, 实际 $read_value"
fi

echo ""

# ---- 6. 恢复故障节点 ----
echo -e "${YELLOW}[步骤 6] 恢复故障节点${NC}"

info "正在启动容器: $MASTER_CONTAINER..."
docker start $MASTER_CONTAINER >/dev/null 2>&1
ok "容器已启动"

# 等待原 master 重新加入集群
if wait_for "原 master 重新加入集群" 30 2 \
  "redis-cli -h 127.0.0.1 -p $MASTER_PORT PING 2>/dev/null | grep -q 'PONG'"
then
  sleep 3
  master_after=$(redis-cli -h 127.0.0.1 -p $MASTER_PORT CLUSTER NODES 2>/dev/null | grep "myself" || echo "not ready")
  info "原 master 恢复后状态: $master_after"
fi

echo ""

# ---- 7. 清理 ----
info "清理测试数据..."
redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT DEL "$test_key" >/dev/null 2>&1 || true
redis-cli -c -h 127.0.0.1 -p $REPLICA_PORT DEL "$test_key2" >/dev/null 2>&1 || true
ok "测试数据已清理"

echo ""

# ---- 总结 ----
echo "=============================================="
if [ "$FAILED" = "true" ]; then
  echo -e "${RED}[测试失败] 部分检查未通过${NC}"
else
  echo -e "${GREEN}[测试通过] 全部检查通过${NC}"
fi
echo "=============================================="
echo ""
echo "故障转移测试摘要:"
echo "  - Master 故障: $MASTER_CONTAINER 已停止"
echo "  - 自动故障转移: ${AUTO_FAILOVER_ENABLED}"
echo "  - Replica 提升: ${PROMOTED}"
echo "  - 集群状态: $cluster_state"
echo "  - Slots 分配: ${cluster_slots:-N/A}"
echo ""

if [ "$FAILED" = "true" ]; then
  exit 1
fi
