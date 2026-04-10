#!/bin/bash

# AiKv 在线槽迁移测试（Redis Cluster 流程）
# 用法: ./test_cluster_migration.sh [host] [src_port] [dst_port]
#
# ---------------------------------------------------------------------------
# 测试用的 key 是什么？
# ---------------------------------------------------------------------------
# 脚本会依次尝试（N=1..300）:
#   {slot_mig_test_N}:k1
# 用「源 master 在 CLUSTER NODES 里出现的第一个槽段」过滤：第一个满足
#   KEYSLOT(key) 落在该段内的 key 即被采用（通常 N=1 即可）。
# 写入的值形如: v_<unix 秒时间戳>
# 运行时会打印一行: [INFO] 测试 key=... slot=...
#
# 手动确认（把下面 HOST/PORT/KEY/SLOT 换成你日志里的；VALUE 为当时 SET 的值）:
#   redis-cli -h HOST -p SRC_PORT CLUSTER KEYSLOT "KEY"
#   redis-cli -h HOST -p SRC_PORT CLUSTER GETKEYSINSLOT SLOT 10
#   redis-cli -c -h HOST -p SRC_PORT GET "KEY"
# 迁移完成后（SETSLOT NODE 之后），同一 GET 应仍返回 VALUE，且 KEYSLOT 不变；
# 槽位应归目标 master（可用 CLUSTER NODES / CLUSTER SLOTS 看）。
# ---------------------------------------------------------------------------

set -e

HOST="${1:-127.0.0.1}"
SRC_PORT="${2:-6379}"
DST_PORT="${3:-6382}"
IMPORTING_WAIT_MS="${IMPORTING_WAIT_MS:-0}"
MIGRATION_NOISE_SECONDS="${MIGRATION_NOISE_SECONDS:-0}"

CLI_SRC="redis-cli -h $HOST -p $SRC_PORT"
CLI_DST="redis-cli -h $HOST -p $DST_PORT"
CLI_CLUSTER="redis-cli -c -h $HOST -p $SRC_PORT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# 硬校验：CLUSTER NODES 里目标 master 行在 connected 之后的槽列表是否覆盖 WantSlot
verify_slot_on_dst_master() {
  local WantSlot="$1"
  local slots_tail
  slots_tail=$($CLI_SRC CLUSTER NODES 2>/dev/null | tr -d '\r' | awk -v id="$dst_id" '
    $1 == id {
      for (i = 1; i <= NF; i++) {
        if ($i == "connected") {
          for (j = i + 1; j <= NF; j++) printf "%s ", $j
          exit
        }
      }
    }
  ')
  [ -n "$slots_tail" ] || fail "硬校验: 无法解析目标节点 $dst_id 的槽列表（CLUSTER NODES）"
  local tok
  for tok in $slots_tail; do
    if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -eq "$WantSlot" ]; then
      ok "硬校验: 槽 $WantSlot 已在目标 master ($dst_id) 的槽列表中"
      return 0
    fi
    if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
      local a=${tok%-*} b=${tok#*-}
      if [ "$WantSlot" -ge "$a" ] && [ "$WantSlot" -le "$b" ]; then
        ok "硬校验: 槽 $WantSlot 已在目标 master ($dst_id) 的槽列表中（段 $tok）"
        return 0
      fi
    fi
  done
  fail "硬校验: 槽 $WantSlot 未出现在目标 master 的槽列表中: $slots_tail"
}

echo "=============================================="
echo " AiKv 在线槽迁移测试 (source=$SRC_PORT target=$DST_PORT)"
echo "=============================================="

src_id=$($CLI_SRC CLUSTER MYID 2>/dev/null | tr -d '\r')
dst_id=$($CLI_DST CLUSTER MYID 2>/dev/null | tr -d '\r')
[ -n "$src_id" ] || fail "无法获取源节点 MYID"
[ -n "$dst_id" ] || fail "无法获取目标节点 MYID"
ok "源节点: $src_id"
ok "目标节点: $dst_id"

# 解析源节点 slot 范围（如 0-8191）
# 不依赖固定字段位置，按 node id + master 角色提取首个 slot range。
src_slot_range=$($CLI_SRC CLUSTER NODES 2>/dev/null | tr -d '\r' | awk -v id="$src_id" '
    $1 == id && $3 ~ /master/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+-[0-9]+$/) { print $i; exit }
        }
    }
')
[ -n "$src_slot_range" ] || fail "无法从 CLUSTER NODES 解析源节点槽范围"
src_slot_start=${src_slot_range%-*}
src_slot_end=${src_slot_range#*-}
info "源节点槽范围: $src_slot_start-$src_slot_end"

# 自动找一个属于源节点槽范围的 key，避免写入被 -c 路由到目标节点
key=""
slot=""
for i in $(seq 1 300); do
    candidate="{slot_mig_test_${i}}:k1"
    candidate_slot=$($CLI_SRC CLUSTER KEYSLOT "$candidate" 2>/dev/null | tr -d '\r')
    if [[ "$candidate_slot" =~ ^[0-9]+$ ]] && [ "$candidate_slot" -ge "$src_slot_start" ] && [ "$candidate_slot" -le "$src_slot_end" ]; then
        key="$candidate"
        slot="$candidate_slot"
        break
    fi
done
[ -n "$key" ] || fail "无法找到落在源节点槽范围内的测试 key"

value="v_$(date +%s)"
set_out=$($CLI_CLUSTER SET "$key" "$value" 2>&1 || true)
[ "$set_out" = "OK" ] || fail "预写入失败: $set_out"
info "测试 key=$key slot=$slot value=$value"
info "手动确认示例: redis-cli -h $HOST -p $SRC_PORT CLUSTER KEYSLOT \"$key\""
info "手动确认示例: redis-cli -h $HOST -p $SRC_PORT CLUSTER GETKEYSINSLOT $slot 10"
info "手动确认示例: redis-cli -c -h $HOST -p $SRC_PORT GET \"$key\""

keys_in_slot=$($CLI_SRC CLUSTER GETKEYSINSLOT "$slot" 10 2>&1 || true)
info "GETKEYSINSLOT: $keys_in_slot"

out=$($CLI_SRC CLUSTER SETSLOT "$slot" MIGRATING "$dst_id" 2>&1 || true)
[ "$out" = "OK" ] || fail "SETSLOT MIGRATING 失败: $out"
ok "SETSLOT MIGRATING"

out=$($CLI_DST CLUSTER SETSLOT "$slot" IMPORTING "$src_id" 2>&1 || true)
[ "$out" = "OK" ] || fail "SETSLOT IMPORTING 失败: $out"
ok "SETSLOT IMPORTING"

if [ "$IMPORTING_WAIT_MS" -gt 0 ] 2>/dev/null; then
  info "IMPORTING 可见性等待 ${IMPORTING_WAIT_MS}ms（诊断开关）"
  sleep "$(awk "BEGIN { printf \"%.3f\", ${IMPORTING_WAIT_MS}/1000 }")"
fi

noise_pid=""
if [ "$MIGRATION_NOISE_SECONDS" -gt 0 ] 2>/dev/null; then
  info "并发噪声写入 ${MIGRATION_NOISE_SECONDS}s（验证 ASKING 隔离）"
  (
    end_ts=$(( $(date +%s) + MIGRATION_NOISE_SECONDS ))
    i=0
    while [ "$(date +%s)" -lt "$end_ts" ]; do
      $CLI_CLUSTER SET "{slot_mig_noise}:$i" "n_$i" >/dev/null 2>&1 || true
      i=$((i+1))
      sleep 0.02
    done
  ) &
  noise_pid=$!
fi

out=$($CLI_SRC MIGRATE "$HOST" "$DST_PORT" "" 0 5000 KEYS "$key" REPLACE 2>&1 || true)
if [ -n "$noise_pid" ]; then
  wait "$noise_pid" || true
fi
case "$out" in
  OK|NOKEY) ok "MIGRATE 返回: $out" ;;
  *) fail "MIGRATE 失败: $out" ;;
esac

out=$($CLI_SRC CLUSTER SETSLOT "$slot" NODE "$dst_id" 2>&1 || true)
[ "$out" = "OK" ] || fail "源节点 SETSLOT NODE 失败: $out"
ok "源节点 SETSLOT NODE 已提交"

# 目标节点常为 MetaRaft follower：直接 NODE 可能返回 ForwardToLeader，但槽位已由 leader 复制（源上 NODE 足够）。
out=$($CLI_DST CLUSTER SETSLOT "$slot" NODE "$dst_id" 2>&1 || true)
if [ "$out" = "OK" ]; then
  ok "目标节点 SETSLOT NODE"
else
  info "目标节点 SETSLOT NODE 未在本地 OK（多为 follower）: $out"
fi

verify_slot_on_dst_master "$slot"

info "硬校验: CLUSTER SLOTS（目标 master 应对外服务端口 $DST_PORT，node id $dst_id）"
$CLI_SRC CLUSTER SLOTS 2>/dev/null | tr -d '\r' | head -n 80 || true

read_out=$($CLI_CLUSTER GET "$key" 2>&1 || true)
[ "$read_out" = "$value" ] || fail "迁移后读取不一致: got=$read_out expect=$value"
ok "迁移后读取一致"

$CLI_CLUSTER DEL "$key" >/dev/null 2>&1 || true
ok "测试完成并清理数据"

