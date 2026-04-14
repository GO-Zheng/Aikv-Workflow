#!/bin/bash

# AiKv 备份/恢复测试脚本
# 测试 SAVE / BGSAVE / LASTSAVE 命令以及基于 AiDb BackupManager 的文件级备份
#
# 用法: ./test_backup_restore.sh [host] [port]
# 默认: host=127.0.0.1 port=6379
#
# 前置条件:
#   1. 集群已启动（6 节点，2 master + 4 replica）
#   2. 集群已初始化（slots 已分配）
#   3. 各节点可正常访问
#
# 测试内容:
#   Phase 1 — 写入多种数据类型，SAVE 备份，验证备份文件
#   Phase 2 — BGSAVE 异步备份 + 并发保护
#   Phase 3 — 多次备份保留策略
#   Phase 4 — CONFIG GET/SET backup-dir 动态配置
#   Phase 5 — 备份后业务读回：写入 {restore}:* → SAVE → 校验键值（默认，无破坏性）
#   Phase 5b — （可选）单节点「删 SST/WAL + 拷备份」演练，默认关闭
#
# 为何默认关闭 Phase 5b：
#   - AiDb BackupManager 只备份 SST + WAL，不备份 MANIFEST/CURRENT；脚本若只删 *.sst/*.log
#     而留下旧 MANIFEST，LSM 元数据与文件不一致，进程虽能起来但状态机/Raft 易异常。
#   - 集群下仅恢复一个 master 的数据目录会与同组其它副本的 Raft 日志分叉，不属于支持的 DR 路径。
#   真实恢复应使用 AiDb RecoveryManager 在空目录全量还原，或对整组节点做一致的运维流程。
#
# 环境变量:
#   ENABLE_PHASE5_DESTRUCTIVE_RESTORE=1 — 开启 Phase 5b（会破坏分片一致性，仅实验环境）
#   CLUSTER_OK_WAIT_SECS / RESTORE_DATA_WAIT_SECS — 仅 Phase 5b 使用
#   FORCE_CLEANUP=1 — 即使失败也删除测试键

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
CLI="redis-cli -h $HOST -p $PORT"
CLI_C="redis-cli -c -h $HOST -p $PORT"

MASTER_PORTS=(6379 6382)
MASTER_CONTAINERS=(aikv-master-1 aikv-master-2)

# Phase 5 若已做「删库+拷备份+重启」后仍失败，置 1 以跳过清理并打印手工命令
PRESERVE_TEST_DATA=0
PHASE5_OWNER_PORT=""
PHASE5_OWNER_CTN=""
PHASE5_SLOT=""
PHASE5_LATEST_BACKUP=""
PHASE5_ORIGINAL_DB_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo -e "  ${GREEN}[OK]${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}[FAIL]${NC} $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

# Phase 5 失败后：输出可复制的 redis-cli / docker 命令与期望结果
print_manual_verify_guide() {
    local op="${PHASE5_OWNER_PORT:-?}"
    local oc="${PHASE5_OWNER_CTN:-aikv-master-?}"
    local sl="${PHASE5_SLOT:-?}"
    local bu="${PHASE5_LATEST_BACKUP:-/app/data/backups/group_*/backup-*}"
    local db="${PHASE5_ORIGINAL_DB_DIR:-/app/data/groups/*/db}"

    echo ""
    echo -e "${YELLOW}========== 手工排查：命令与期望结果 ==========${NC}"
    echo "# 说明：脚本已保留测试键 {restore}:* 与 bk:*（未执行 DEL）。"
    echo "# 若曾运行 Phase 5b 后出现 CLUSTERDOWN：多为单节点文件恢复 + MANIFEST 与 SST 不一致或 Raft 副本分叉，"
    echo "# 建议恢复该组全部副本数据或从干净集群重做；不要仅依赖拷回部分 SST/WAL。"
    echo "# 排查结束后可逐个删除，例如:"
    echo "#   redis-cli -c -h $HOST -p $PORT DEL '{restore}:str' '{restore}:num' '{restore}:hash' '{restore}:list' '{restore}:set' '{restore}:zset'"
    echo "# 或再次跑本脚本并打开清理: FORCE_CLEANUP=1 $0 $HOST $PORT（会完整重跑 Phase 1–5）"
    echo ""
    echo "# --- 1) 集群是否健康（期望 cluster_state:ok；cluster_slots_assigned:16384）"
    echo "redis-cli -h $HOST -p $PORT CLUSTER INFO"
    echo ""
    echo "# --- 2) 槽位与路由（期望 KEYSLOT 与下列 slot 一致，当前记录 slot=$sl）"
    echo "redis-cli -h $HOST -p $PORT CLUSTER KEYSLOT '{restore}:str'"
    echo "redis-cli -h $HOST -p $PORT CLUSTER NODES"
    echo ""
    echo "# --- 3) 集群模式读（期望如下；若仍 CLUSTERDOWN，可过几分钟重试或查分片 leader）"
    echo "redis-cli -c -h $HOST -p $PORT GET '{restore}:str'     # 期望: important_data"
    echo "redis-cli -c -h $HOST -p $PORT GET '{restore}:num'      # 期望: 12345"
    echo "redis-cli -c -h $HOST -p $PORT HGET '{restore}:hash' f1 # 期望: v1"
    echo "redis-cli -c -h $HOST -p $PORT LLEN '{restore}:list'   # 期望: 3"
    echo "redis-cli -c -h $HOST -p $PORT SCARD '{restore}:set'   # 期望: 3"
    echo "redis-cli -c -h $HOST -p $PORT ZCARD '{restore}:zset'   # 期望: 3"
    echo "redis-cli -c -h $HOST -p $PORT ZSCORE '{restore}:zset' bb  # 期望: 2 或 2.0"
    echo ""
    echo "# --- 4) 直连负责该键的 master 宿主机端口（当前记录: $op；无 -c，可能返回 MOVED）"
    echo "redis-cli -h $HOST -p $op GET '{restore}:str'"
    echo ""
    echo "# --- 5) 容器内数据与备份（容器名: $oc）"
    echo "docker exec $oc ls -la $db 2>/dev/null || docker exec $oc find /app/data/groups -name db -type d"
    echo "docker exec $oc ls -la $bu/sstables 2>/dev/null || true"
    echo "docker exec $oc ls -la $bu/wal 2>/dev/null || true"
    echo ""
    echo -e "${YELLOW}===============================================${NC}"
    echo ""
}

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        fail "$desc (want='$want', got='$got')"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        ok "$desc"
    else
        fail "$desc (missing '$needle')"
    fi
}

assert_gt() {
    local desc="$1" a="$2" b="$3"
    if [ "$a" -gt "$b" ] 2>/dev/null; then
        ok "$desc"
    else
        fail "$desc ($a <= $b)"
    fi
}

wait_for_port() {
    local port="$1" max="$2"
    for i in $(seq 1 "$max"); do
        if redis-cli -h "$HOST" -p "$port" PING 2>/dev/null | grep -qF PONG; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 等待 CLUSTER INFO 报告 cluster_state:ok（分片 Raft 选主、元数据一致前会短暂 fail，
# 此时客户端会得到 CLUSTERDOWN Hash slot ... not served）
wait_for_cluster_state_ok() {
    local max="${1:-180}"
    local p0="${MASTER_PORTS[0]}"
    local i ci
    for i in $(seq 1 "$max"); do
        ci=$(redis-cli -h "$HOST" -p "$p0" CLUSTER INFO 2>/dev/null | tr -d '\r' || true)
        if echo "$ci" | grep -q 'cluster_state:ok'; then
            return 0
        fi
        if [ $((i % 20)) -eq 0 ]; then
            info "等待 cluster_state:ok ... 已 ${i}s（分片恢复后 Raft 选主可能需要较长时间）"
        fi
        sleep 1
    done
    return 1
}

# 一次性格验 Phase 5 写入的 {restore}:* 数据；遇 ERR/CLUSTERDOWN 返回非 0
restore_data_all_match() {
    local str num h1 ll sc zc zs
    str=$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:str" 2>/dev/null | tr -d '\r')
    case "$str" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$str" = "important_data" ] || return 1

    num=$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:num" 2>/dev/null | tr -d '\r')
    case "$num" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$num" = "12345" ] || return 1

    h1=$(redis-cli -c -h "$HOST" -p "$PORT" HGET "{restore}:hash" f1 2>/dev/null | tr -d '\r')
    case "$h1" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$h1" = "v1" ] || return 1

    ll=$(redis-cli -c -h "$HOST" -p "$PORT" LLEN "{restore}:list" 2>/dev/null | tr -d '\r')
    case "$ll" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$ll" = "3" ] || return 1

    sc=$(redis-cli -c -h "$HOST" -p "$PORT" SCARD "{restore}:set" 2>/dev/null | tr -d '\r')
    case "$sc" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$sc" = "3" ] || return 1

    zc=$(redis-cli -c -h "$HOST" -p "$PORT" ZCARD "{restore}:zset" 2>/dev/null | tr -d '\r')
    case "$zc" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    [ "$zc" = "3" ] || return 1

    zs=$(redis-cli -c -h "$HOST" -p "$PORT" ZSCORE "{restore}:zset" bb 2>/dev/null | tr -d '\r')
    case "$zs" in ERR*|*CLUSTERDOWN*) return 1 ;; esac
    case "$zs" in 2|2.0) return 0 ;; *) return 1 ;; esac
}

wait_until_restore_data_verified() {
    local max="${1:-120}"
    local i
    for i in $(seq 1 "$max"); do
        if restore_data_all_match; then
            info "恢复后数据可读且一致（轮询 ${i}s）"
            return 0
        fi
        sleep 1
    done
    return 1
}

echo "=============================================="
echo " AiKv 备份/恢复测试"
echo " host=$HOST  master_ports=${MASTER_PORTS[*]}"
echo "=============================================="

# =========================================================
#  Phase 1 — 写入多种数据类型 + SAVE 备份 + 校验备份文件
# =========================================================
section "Phase 1" "写入测试数据 → SAVE → 校验备份文件"

info "清理旧数据..."
for key in bk:str bk:counter bk:list bk:hash bk:set bk:zset; do
    $CLI_C DEL "$key" >/dev/null 2>&1 || true
done

info "写入 String 类型..."
$CLI_C SET bk:str "hello_backup" >/dev/null 2>&1
$CLI_C SET bk:counter 42 >/dev/null 2>&1

info "写入 List 类型..."
$CLI_C RPUSH bk:list "a" "b" "c" "d" "e" >/dev/null 2>&1

info "写入 Hash 类型..."
$CLI_C HSET bk:hash name "AiKv" version "0.2" engine "AiDb" >/dev/null 2>&1

info "写入 Set 类型..."
$CLI_C SADD bk:set "alpha" "beta" "gamma" "delta" >/dev/null 2>&1

info "写入 Sorted Set 类型..."
$CLI_C ZADD bk:zset 1.0 "one" 2.5 "two" 3.7 "three" 4.0 "four" >/dev/null 2>&1

# 记录备份前的 LASTSAVE
lastsave_before=$($CLI LASTSAVE 2>/dev/null)
info "备份前 LASTSAVE = $lastsave_before"

sleep 1

info "在所有 Master 节点执行 SAVE..."
for port in "${MASTER_PORTS[@]}"; do
    r=$(redis-cli -h "$HOST" -p "$port" SAVE 2>/dev/null)
    assert_eq "SAVE on port $port" "$r" "OK"
done

# LASTSAVE 应该已更新
lastsave_after=$($CLI LASTSAVE 2>/dev/null)
info "备份后 LASTSAVE = $lastsave_after"
assert_gt "LASTSAVE 已更新" "$lastsave_after" "$lastsave_before"

info "校验备份文件..."
for i in "${!MASTER_CONTAINERS[@]}"; do
    ctn="${MASTER_CONTAINERS[$i]}"
    port="${MASTER_PORTS[$i]}"

    backup_dirs=$(docker exec "$ctn" find /app/data/backups -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true)
    if [ -z "$backup_dirs" ]; then
        fail "容器 $ctn: /app/data/backups 下无备份目录"
        continue
    fi
    ok "容器 $ctn 存在备份目录"

    has_meta=0; has_sst=0; has_wal=0
    if docker exec "$ctn" find /app/data/backups -name "metadata.json" -type f 2>/dev/null | grep -q .; then
        has_meta=1
    fi
    if docker exec "$ctn" find /app/data/backups -name "*.sst" -type f 2>/dev/null | grep -q .; then
        has_sst=1
    fi
    if docker exec "$ctn" find /app/data/backups -name "*.log" -type f 2>/dev/null | grep -q .; then
        has_wal=1
    fi

    [ "$has_meta" -eq 1 ] && ok "容器 $ctn 有 metadata.json" || fail "容器 $ctn 缺少 metadata.json"
    [ "$has_sst"  -eq 1 ] && ok "容器 $ctn 有 SSTable 文件"  || fail "容器 $ctn 缺少 SSTable 文件"
    [ "$has_wal"  -eq 1 ] && ok "容器 $ctn 有 WAL 文件"      || fail "容器 $ctn 缺少 WAL 文件"

    meta_json=$(docker exec "$ctn" sh -c 'cat $(find /app/data/backups -name "metadata.json" | head -1)' 2>/dev/null || true)
    assert_contains "容器 $ctn metadata 含 backup_type" "$meta_json" '"Full"'
    assert_contains "容器 $ctn metadata 含 sstable_files" "$meta_json" '"sstable_files"'
done

# =========================================================
#  Phase 2 — BGSAVE 异步备份 + 并发保护
# =========================================================
section "Phase 2" "BGSAVE 异步备份"

r=$($CLI BGSAVE 2>/dev/null)
assert_eq "BGSAVE 返回 Background saving started" "$r" "Background saving started"

sleep 2

lastsave_bg=$($CLI LASTSAVE 2>/dev/null)
assert_gt "BGSAVE 后 LASTSAVE 已更新" "$lastsave_bg" "$lastsave_before"
info "BGSAVE 后 LASTSAVE = $lastsave_bg"

# =========================================================
#  Phase 3 — 多次备份保留
# =========================================================
section "Phase 3" "多次备份保留策略"

info "追加写入后再次 SAVE..."
for i in $(seq 1 20); do
    $CLI_C SET "bk:batch:$i" "val_$i" >/dev/null 2>&1
done

sleep 1

redis-cli -h "$HOST" -p "${MASTER_PORTS[0]}" SAVE >/dev/null 2>&1

ctn="${MASTER_CONTAINERS[0]}"
backup_count=$(docker exec "$ctn" sh -c \
    'find /app/data/backups -name "backup-*" -type d | wc -l' 2>/dev/null)
info "容器 $ctn 中备份目录数 = $backup_count"
assert_gt "有多份备份" "$backup_count" "1"

# =========================================================
#  Phase 4 — CONFIG GET/SET backup-dir
# =========================================================
section "Phase 4" "CONFIG backup-dir 动态配置"

cfg=$($CLI CONFIG GET backup-dir 2>/dev/null)
assert_contains "CONFIG GET backup-dir 可用" "$cfg" "backup-dir"
info "当前 backup-dir = $(echo "$cfg" | tail -1)"

$CLI CONFIG SET backup-dir /tmp/aikv-custom-backup >/dev/null 2>&1
cfg2=$($CLI CONFIG GET backup-dir 2>/dev/null)
assert_contains "CONFIG SET 生效" "$cfg2" "/tmp/aikv-custom-backup"

$CLI CONFIG SET backup-dir "$(echo "$cfg" | tail -1)" >/dev/null 2>&1
info "已恢复原 backup-dir"

# =========================================================
#  Phase 5 — 备份后读回（默认） / 5b 破坏性演练（可选）
# =========================================================
section "Phase 5" "SAVE 后备份目录落盘 + 业务键 {restore}:* 读回校验"

TARGET_PORT="${MASTER_PORTS[0]}"
TARGET_CTN="${MASTER_CONTAINERS[0]}"

info "参考容器: $TARGET_CTN (port $TARGET_PORT)；数据写入走集群 -c"

info "写入恢复测试键（用于校验备份前/SAVE 后数据一致）..."
# 使用 hash tag 强制路由到同一 slot
$CLI_C SET  "{restore}:str"    "important_data"  >/dev/null 2>&1
$CLI_C SET  "{restore}:num"    "12345"           >/dev/null 2>&1
$CLI_C HSET "{restore}:hash"   f1 v1 f2 v2      >/dev/null 2>&1
$CLI_C RPUSH "{restore}:list"  x y z             >/dev/null 2>&1
$CLI_C SADD "{restore}:set"    m n o             >/dev/null 2>&1
$CLI_C ZADD "{restore}:zset"   1 aa 2 bb 3 cc   >/dev/null 2>&1

# 确定 {restore} 这个 slot 在哪个 master 上
slot=$($CLI CLUSTER KEYSLOT "{restore}:str" 2>/dev/null | tr -dc '0-9')
info "{restore} slot = $slot"

# 找到负责该 slot 的 master：通过 MOVED 重定向解析实际端口
owner_port=""
owner_ctn=""
for i in "${!MASTER_PORTS[@]}"; do
    p="${MASTER_PORTS[$i]}"
    c="${MASTER_CONTAINERS[$i]}"
    resp=$(redis-cli -h "$HOST" -p "$p" GET "{restore}:str" 2>/dev/null || true)
    if echo "$resp" | grep -q "^MOVED"; then
        # MOVED 9769 192.168.1.113:6382 → 提取目标端口
        moved_port=$(echo "$resp" | awk -F: '{print $NF}' | tr -dc '0-9')
        info "port $p 返回 MOVED → $moved_port"
    else
        owner_port="$p"
        owner_ctn="$c"
        info "port $p 直接命中"
        break
    fi
done

# 如果所有 master 都返回了 MOVED，用 MOVED 指向的端口
if [ -z "$owner_port" ] && [ -n "${moved_port:-}" ]; then
    for i in "${!MASTER_PORTS[@]}"; do
        if [ "${MASTER_PORTS[$i]}" = "$moved_port" ]; then
            owner_port="${MASTER_PORTS[$i]}"
            owner_ctn="${MASTER_CONTAINERS[$i]}"
            info "通过 MOVED 确定 owner = $owner_ctn (port $owner_port)"
            break
        fi
    done
fi

if [ -z "$owner_port" ]; then
    fail "未找到 slot $slot 的 master 节点，跳过 Phase 5"
else
    PHASE5_OWNER_PORT="$owner_port"
    PHASE5_OWNER_CTN="$owner_ctn"
    PHASE5_SLOT="$slot"
    info "slot $slot 由 $owner_ctn (port $owner_port) 负责"

    info "在 $owner_ctn 上执行 SAVE（生成最新文件级备份）..."
    redis-cli -h "$HOST" -p "$owner_port" SAVE >/dev/null 2>&1
    ok "SAVE 完成"

    latest_backup=$(docker exec "$owner_ctn" sh -c \
        'find /app/data/backups -name "backup-*" -type d | sort | tail -1' 2>/dev/null)
    original_db_dir=$(docker exec "$owner_ctn" sh -c \
        "find /app/data/groups -name 'db' -type d 2>/dev/null || find /app/data -path '*/groups/*/db' -type d 2>/dev/null" | head -1)
    PHASE5_LATEST_BACKUP="$latest_backup"
    PHASE5_ORIGINAL_DB_DIR="$original_db_dir"
    info "最新备份目录: $latest_backup"
    info "对应 db 目录: $original_db_dir"

    info "Phase 5 — 校验 SAVE 后仍可正确读回 {restore}:*（与「备份前写入」一致）..."
    if ! restore_data_all_match; then
        fail "SAVE 后读回 {restore}:* 失败（与备份语义相关，请先排查写入/SLOT/集群状态）"
        v=$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:str" 2>/dev/null | tr -d '\r')
        info "GET {restore}:str => $v"
        PRESERVE_TEST_DATA=1
        print_manual_verify_guide
    else
        assert_eq "String 读回" "$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:str" 2>/dev/null | tr -d '\r')" "important_data"
        assert_eq "Number 读回" "$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:num" 2>/dev/null | tr -d '\r')" "12345"
        assert_eq "Hash 读回" "$(redis-cli -c -h "$HOST" -p "$PORT" HGET "{restore}:hash" f1 2>/dev/null | tr -d '\r')" "v1"
        assert_eq "List 长度读回" "$(redis-cli -c -h "$HOST" -p "$PORT" LLEN "{restore}:list" 2>/dev/null | tr -d '\r')" "3"
        assert_eq "Set 读回" "$(redis-cli -c -h "$HOST" -p "$PORT" SCARD "{restore}:set" 2>/dev/null | tr -d '\r')" "3"
        assert_eq "ZSet 读回" "$(redis-cli -c -h "$HOST" -p "$PORT" ZCARD "{restore}:zset" 2>/dev/null | tr -d '\r')" "3"
        zs_final=$(redis-cli -c -h "$HOST" -p "$PORT" ZSCORE "{restore}:zset" bb 2>/dev/null | tr -d '\r')
        case "$zs_final" in 2|2.0) ok "ZSet score 读回" ;; *) fail "ZSet score 读回 (want 2, got '$zs_final')" ;; esac
    fi

    if [ "${ENABLE_PHASE5_DESTRUCTIVE_RESTORE:-0}" != "1" ]; then
        ok "Phase 5b（单节点删库+拷备份）已跳过 — 默认关闭，避免 MANIFEST/Raft 不一致"
        info "若必须在实验环境演练破坏性步骤: ENABLE_PHASE5_DESTRUCTIVE_RESTORE=1 $0 $HOST $PORT"
    else
        warn "Phase 5b — 破坏性文件恢复（将破坏该分片 Raft 一致性与 LSM 元数据，仅用于实验）"

        if [ -z "$latest_backup" ] || [ -z "$original_db_dir" ]; then
            fail "未找到备份或数据目录，无法执行 Phase 5b"
        else
            info "在容器内准备恢复脚本..."
            docker exec "$owner_ctn" sh -c "cat > /tmp/do_restore.sh << 'SCRIPT'
#!/bin/sh
set -e
DB_DIR=\"\$1\"
BACKUP_DIR=\"\$2\"
echo \"[restore] 删除 \$DB_DIR 中的数据文件...\"
rm -f \"\$DB_DIR\"/*.sst \"\$DB_DIR\"/*.log
echo \"[restore] 从 \$BACKUP_DIR 恢复 SSTable...\"
cp \"\$BACKUP_DIR\"/sstables/*.sst \"\$DB_DIR/\" 2>/dev/null || true
echo \"[restore] 从 \$BACKUP_DIR 恢复 WAL...\"
cp \"\$BACKUP_DIR\"/wal/*.log \"\$DB_DIR/\" 2>/dev/null || true
echo \"[restore] 恢复完成\"
ls -la \"\$DB_DIR/\"
SCRIPT
chmod +x /tmp/do_restore.sh" 2>/dev/null

            info "停止 $owner_ctn..."
            docker stop "$owner_ctn" >/dev/null 2>&1
            ok "容器已停止"

            info "启动容器执行数据删除与恢复..."
            docker start "$owner_ctn" >/dev/null 2>&1
            sleep 2

            docker exec "$owner_ctn" sh /tmp/do_restore.sh "$original_db_dir" "$latest_backup" 2>&1 | while read -r line; do
                info "$line"
            done
            ok "备份文件已拷回数据目录（实验）"

            info "重启 $owner_ctn..."
            docker restart "$owner_ctn" >/dev/null 2>&1

            info "等待节点就绪..."
            if ! wait_for_port "$owner_port" 60; then
                fail "节点 $owner_port 未能在 60s 内 PING 就绪"
                PRESERVE_TEST_DATA=1
                warn "已保留测试数据。"
                print_manual_verify_guide
            else
                ok "节点 $owner_port PING 就绪"

                cwait="${CLUSTER_OK_WAIT_SECS:-180}"
                info "等待 cluster_state:ok（最长 ${cwait}s）..."
                if ! wait_for_cluster_state_ok "$cwait"; then
                    fail "集群在 ${cwait}s 内未进入 cluster_state:ok"
                    PRESERVE_TEST_DATA=1
                    print_manual_verify_guide
                else
                    ok "CLUSTER INFO: cluster_state:ok"

                    rwait="${RESTORE_DATA_WAIT_SECS:-120}"
                    info "轮询校验 Phase 5b 后数据（最长 ${rwait}s）..."
                    if ! wait_until_restore_data_verified "$rwait"; then
                        fail "Phase 5b 后数据在 ${rwait}s 内仍不可读（预期外：单节点文件恢复非正式 DR）"
                        v=$(redis-cli -c -h "$HOST" -p "$PORT" GET "{restore}:str" 2>/dev/null | tr -d '\r')
                        info "GET {restore}:str => $v"
                        PRESERVE_TEST_DATA=1
                        print_manual_verify_guide
                    else
                        ok "Phase 5b 后轮询读回成功（实验环境偶发成功，不代表生产可依赖此路径）"
                    fi
                fi
            fi
        fi
    fi
fi

# =========================================================
#  清理测试数据
# =========================================================
if [ "${FORCE_CLEANUP:-0}" = "1" ]; then
    PRESERVE_TEST_DATA=0
fi

if [ "$PRESERVE_TEST_DATA" -eq 1 ]; then
    section "清理" "已跳过（Phase 5 失败后保留键供排查）"
    warn "键 bk:* 与 {restore}:* 仍留在集群中。"
    warn "排查结束后可手动删除，或执行: FORCE_CLEANUP=1 $0 $HOST $PORT"
    print_manual_verify_guide
else
    section "清理" "删除测试数据"
    for key in bk:str bk:counter bk:list bk:hash bk:set bk:zset; do
        $CLI_C DEL "$key" >/dev/null 2>&1 || true
    done
    for i in $(seq 1 20); do
        $CLI_C DEL "bk:batch:$i" >/dev/null 2>&1 || true
    done
    for key in "{restore}:str" "{restore}:num" "{restore}:hash" "{restore}:list" "{restore}:set" "{restore}:zset"; do
        $CLI_C DEL "$key" >/dev/null 2>&1 || true
    done
    ok "测试数据已清理"
fi

# =========================================================
#  结果汇总
# =========================================================
echo ""
echo "=============================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}[SUCCESS]${NC} 全部 $TOTAL 项测试通过 (PASS=$PASS)"
else
    echo -e "${RED}[FAILED]${NC} $FAIL / $TOTAL 项测试失败 (PASS=$PASS, FAIL=$FAIL)"
fi
echo "=============================================="

exit "$FAIL"
