#!/bin/bash
#
# 集群扩容：将「已启动、尚未加入拓扑」的新 master 纳入 MetaRaft + CLUSTER 视图，且 **不分配槽位**。
# 槽位由后续 redis-cli / test_cluster_migration.sh 等迁移流程再划给该节点。
#
# 用法:
#   ./test_cluster_expand_master.sh [host] [bootstrap_redis_port] [new_master_redis_port] [new_master_raft_addr]
#
# 示例（新节点容器内 Raft 监听 50051，与其它 master 一样）:
#   ./test_cluster_expand_master.sh 127.0.0.1 6379 6385 aikv-master-3:50051
#
# 环境变量（与 scripts/init_cluster.sh 一致）:
#   REDIS_CLI              默认 redis-cli
#   CLUSTER_REDIS_CONNECT_HOST  若本机 hairpin 不通，可设为 127.0.0.1，端口仍用参数中的端口
#
# 本机 Docker 扩容容器（默认开启，当 HOST 为 127.0.0.1 / localhost 时）:
#   若容器 EXPAND_CONTAINER_NAME（默认 aikv-master-3）已在运行 → 跳过；
#   若存在但未运行 → docker start；
#   若不存在 → docker compose -f docker/docker-compose-expand.yaml up -d
#   AIKV_EXPAND_SKIP_DOCKER=1     禁用上述逻辑（连远程集群时用）
#   AIKV_EXPAND_FORCE_DOCKER=1    HOST 非本机仍尝试本机 compose（少用）
#   EXPAND_CONTAINER_NAME         默认 aikv-master-3，须与 docker-compose-expand.yaml 中 container_name 一致
#   EXPAND_COMPOSE_FILE           相对 Aikv-Workflow 根的路径，默认 docker/docker-compose-expand.yaml
#   EXPAND_COMPOSE_REDIS_PORT     compose 映射到宿主机的 Redis 端口，默认 6385；仅当 NEW_PORT 与其一致时才自动 compose
#
# ---------------------------------------------------------------------------
# 要不要一次加 3 个节点（1 主 2 从）？
# ---------------------------------------------------------------------------
# - **仅测迁移 / 功能**：**只加 1 个新 master 即可**。新分片在第一次 ADDSLOTS / SETSLOT NODE
#   写入前会 `create_group`，数据 Raft 组初始只有该节点 1 个 voter，**多数派=1**，**SET 不会因「缺副本」失败**。
# - **生产 / 容灾**：建议每个分片 **至少 3 副本（1 主 2 从）**，与 docker-compose-cluster 一致；否则主挂即该分片不可用。
#   加从节点请在本脚本成功后，参考 init_cluster.sh 步骤 7 / 7.5：CLUSTER ADDREPLICATION、
#   以及对副本的 CLUSTER METARAFT ADDLEARNER + PROMOTE（此处不展开，避免与具体 compose 主机名强绑定）。
# ---------------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

HOST="${1:-127.0.0.1}"
BOOT_PORT="${2:-6379}"
NEW_PORT="${3:?缺少参数: new_master_redis_port}"
# 容器间 gRPC 地址，须能被 **bootstrap 与其它 master 容器** 访问（常为 Docker service 名:50051）
NEW_RAFT="${4:?缺少参数: new_master_raft_addr 例如 aikv-master-3:50051}"

REDIS_CLI="${REDIS_CLI:-redis-cli}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 本机 Docker：保障扩容用 master 容器（与 docker-compose-expand.yaml 配套）
ensure_expand_master_container() {
  if [[ "${AIKV_EXPAND_SKIP_DOCKER:-}" == "1" ]]; then
    info "已设置 AIKV_EXPAND_SKIP_DOCKER=1，跳过容器检测与 compose"
    return 0
  fi
  command -v docker >/dev/null 2>&1 || return 0

  local hl="${HOST,,}"
  if [[ "$hl" != "127.0.0.1" && "$hl" != "localhost" && -z "${AIKV_EXPAND_FORCE_DOCKER:-}" ]]; then
    info "HOST=$HOST 非本机，跳过 Docker 容器保障（远程请设 AIKV_EXPAND_SKIP_DOCKER=1 显式关闭，或 AIKV_EXPAND_FORCE_DOCKER=1 强制本机 compose）"
    return 0
  fi

  local cname="${EXPAND_CONTAINER_NAME:-aikv-master-3}"
  local crelpath="${EXPAND_COMPOSE_FILE:-docker/docker-compose-expand.yaml}"
  local compose="${WF_ROOT}/${crelpath}"
  if [[ ! -f "$compose" ]]; then
    warn "未找到 compose 文件 ${compose}，跳过容器保障"
    return 0
  fi

  local map_port="${EXPAND_COMPOSE_REDIS_PORT:-6385}"
  if [[ "${NEW_PORT}" != "${map_port}" ]]; then
    info "NEW_PORT=${NEW_PORT} 与 compose 默认宿主机 Redis 端口 ${map_port} 不一致，跳过自动 Docker（请自行启动实例或改 EXPAND_COMPOSE_REDIS_PORT / compose 映射）"
    return 0
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    ok "容器 ${cname} 已在运行，跳过 compose up"
    return 0
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    info "检测到已存在但未运行的容器 ${cname}，执行 docker start…"
    docker start "$cname" || fail "docker start ${cname} 失败"
    ok "已启动容器 ${cname}"
    return 0
  fi

  info "未检测到容器 ${cname}，执行: docker compose -f … up -d"
  if ! docker compose -f "$compose" up -d 2>&1; then
    fail "compose 启动失败。请先确保集群已 up 且网络 aikv-workflow 已存在: docker compose -f docker/docker-compose-cluster.yaml up -d"
  fi
  ok "已通过 compose 创建/启动 ${cname}"
}

redis_cli_bp() {
  local data_port="$1"
  if [[ -n "${CLUSTER_REDIS_CONNECT_HOST:-}" ]]; then
    echo "${CLUSTER_REDIS_CONNECT_HOST} ${data_port}"
  else
    echo "${HOST} ${data_port}"
  fi
}

read -r BS_CLI_H BS_CLI_P <<< "$(redis_cli_bp "${BOOT_PORT}")"
read -r NEW_CLI_H NEW_CLI_P <<< "$(redis_cli_bp "${NEW_PORT}")"

CLI_BS=(redis-cli -h "${BS_CLI_H}" -p "${BS_CLI_P}")
CLI_NEW=(redis-cli -h "${NEW_CLI_H}" -p "${NEW_CLI_P}")

echo "=============================================="
echo " AiKv 扩容：新 master 入群（无槽位）"
echo " bootstrap=${HOST}:${BOOT_PORT}  new_master=${HOST}:${NEW_PORT}"
echo " new_raft=${NEW_RAFT}"
echo "=============================================="

ensure_expand_master_container

wait_ping() {
  local label="$1"
  local max="${2:-60}"
  local i=0
  while [[ "$i" -lt "$max" ]]; do
    if "${CLI_NEW[@]}" PING 2>/dev/null | grep -q PONG; then
      ok "${label} 已就绪"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  fail "${label} 在 ${max}s 内未 PONG"
}

wait_ping "新 master Redis"

new_id=$("${CLI_NEW[@]}" CLUSTER MYID 2>/dev/null | tr -d '\r')
bs_id=$("${CLI_BS[@]}" CLUSTER MYID 2>/dev/null | tr -d '\r')
[[ -n "$new_id" ]] || fail "无法读取新节点 CLUSTER MYID"
[[ -n "$bs_id" ]] || fail "无法读取 bootstrap CLUSTER MYID"
ok "新 master MYID=${new_id}"
ok "bootstrap MYID=${bs_id}"

# METARAFT：与 init_cluster 一致，地址为容器内 gRPC（通常无 http:// 前缀，服务端会规范化）
info "METARAFT ADDLEARNER ${new_id} ${NEW_RAFT}"
out=$("${CLI_BS[@]}" CLUSTER METARAFT ADDLEARNER "${new_id}" "${NEW_RAFT}" 2>&1 || true)
echo "$out"
echo "$out" | grep -q "OK" || warn "ADDLEARNER 输出未含 OK（若已加入可能重复执行）"

sleep 2
info "METARAFT PROMOTE ${new_id}"
out=$("${CLI_BS[@]}" CLUSTER METARAFT PROMOTE "${new_id}" 2>&1 || true)
echo "$out"
echo "$out" | grep -q "OK" || warn "PROMOTE 输出未含 OK"

sleep 2

# 双向 MEET，便于元数据传播（第三参为对方 MYID）
info "CLUSTER MEET: bootstrap -> new (${HOST} ${NEW_PORT} ${new_id})"
out=$("${CLI_BS[@]}" CLUSTER MEET "${HOST}" "${NEW_PORT}" "${new_id}" 2>&1 || true)
echo "$out"
echo "$out" | grep -q "OK" || fail "bootstrap MEET new 失败: $out"

info "CLUSTER MEET: new -> bootstrap (${HOST} ${BOOT_PORT} ${bs_id})"
out=$("${CLI_NEW[@]}" CLUSTER MEET "${HOST}" "${BOOT_PORT}" "${bs_id}" 2>&1 || true)
echo "$out"
echo "$out" | grep -q "OK" || fail "new MEET bootstrap 失败: $out"

sleep 2

# 与其它已知 master 再 MEET 一次（两主场景下把 master-2 拉进新节点视图，减少仅靠 gossip 的等待）
while read -r line; do
  mid=$(echo "$line" | awk '{print $1}')
  flags=$(echo "$line" | awk '{print $3}')
  [[ "$flags" == *master* ]] || continue
  [[ "$mid" == "$new_id" ]] && continue
  [[ "$mid" == "$bs_id" ]] && continue
  tip=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
  th="${tip%%:*}"
  tp="${tip##*:}"
  [[ -n "$th" && -n "$tp" ]] || continue
  info "CLUSTER MEET: new -> 其它 master ${th}:${tp} (${mid})"
  out=$("${CLI_NEW[@]}" CLUSTER MEET "${th}" "${tp}" "${mid}" 2>&1 || true)
  echo "$out"
done < <("${CLI_BS[@]}" CLUSTER NODES 2>/dev/null | tr -d '\r')

sleep 2

info "扩容后 CLUSTER NODES（节选，新 master 应无槽位或 slots 为空）:"
"${CLI_BS[@]}" CLUSTER NODES 2>/dev/null | tr -d '\r' | grep -F "${new_id}" || true

ok "扩容完成：新 master 已在集群中，请再执行槽迁移（例如 tests/test_cluster_migration.sh）把部分 slot 迁到 ${HOST}:${NEW_PORT}"
