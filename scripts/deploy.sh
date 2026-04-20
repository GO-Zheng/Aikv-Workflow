#!/usr/bin/env bash
# 将 Aikv-Workflow 文件同步到 Monitor / Server 主机(默认两台都同步)
#
# 依赖: docker/.env 中至少 MONITOR_HOST、SERVER_HOST(可复制 docker/.env.example)
# 用法:
#   ./deploy.sh               # 仅同步; 本机检查 compose 相关镜像
#   ./deploy.sh -m|--monitor  # 仅 Monitor
#   ./deploy.sh -s|--server   # 仅 Server
#   ./deploy.sh -c|--cluster  # 集群模式: Monitor 用 run_monitor --cluster; Server 用 run_cluster.sh
#   ./deploy.sh -p|--promtail # Monitor 侧镜像检查含 promtail; 远端 run_monitor 加 -p
#   ./deploy.sh -r|--run      # 同步成功后检查镜像通过则 SSH 远端执行脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"
ENV_FILE="$DOCKER_DIR/.env"
REMOTE_DEST="/root/Aikv-Workflow"
CONFIG_SCRIPT="$SCRIPT_DIR/config.sh"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

usage() {
  cat <<EOF
用法: $(basename "$0") [-m|--monitor] [-s|--server] [-c|--cluster] [-p|--promtail] [-r|--run] [-h|--help]

  默认同步两台主机; 仅 -m / 仅 -s 见上。

  -c, --cluster  集群模式开关:
                 - Monitor: 镜像检查包含 docker-compose-cluster-monitor.yaml,-r 时执行 run_monitor.sh --cluster
                 - Server : -r 时执行 run_cluster.sh(否则 run_docker.sh)

  -p, --promtail Monitor 部署: 本机镜像检查包含 docker-compose-promtail.yaml;
                 与 -r 联用时由本机直连 SERVER_HOST 执行 promtail compose up -d

  -r, --run      同步且镜像检查通过后 SSH 执行:
                 Monitor → run_monitor.sh(按需附加 --cluster/--promtail)
                 Server  → 默认 run_docker.sh;加 -c 时 run_cluster.sh

  Monitor: $REMOTE_DEST/ 下 docker scripts
  Server:  $REMOTE_DEST/ 下 config docker scripts tests
EOF
}

DO_MONITOR=0
DO_SERVER=0
REMOTE_RUN=0
SERVER_RUN_KIND=docker
MONITOR_CLUSTER=0
MONITOR_PROMTAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m | --monitor) DO_MONITOR=1; shift ;;
    -s | --server) DO_SERVER=1; shift ;;
    -c | --cluster) MONITOR_CLUSTER=1; shift ;;
    -p | --promtail) MONITOR_PROMTAIL=1; shift ;;
    -r | --run)
      REMOTE_RUN=1
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo -e "${RED}未知参数: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$DO_MONITOR" -eq 0 && "$DO_SERVER" -eq 0 ]]; then
  DO_MONITOR=1
  DO_SERVER=1
fi

# 语义统一: 只要给了 -c 且 -r, Server 默认按集群运行(m/s 可同时生效)
if [[ "$DO_SERVER" -eq 1 && "$MONITOR_CLUSTER" -eq 1 && "$REMOTE_RUN" -eq 1 && "$SERVER_RUN_KIND" == "docker" ]]; then
  SERVER_RUN_KIND=cluster
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}缺少 $ENV_FILE, 请复制 docker/.env.example 并填写 MONITOR_HOST、SERVER_HOST${NC}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${MONITOR_HOST:?请在 docker/.env 中设置 MONITOR_HOST}"
: "${SERVER_HOST:?请在 docker/.env 中设置 SERVER_HOST}"

if [[ ! -x "$CONFIG_SCRIPT" ]]; then
  echo -e "${RED}缺少可执行脚本: $CONFIG_SCRIPT (请 chmod +x)${NC}" >&2
  exit 1
fi

if [[ "$DO_MONITOR" -eq 1 || "$MONITOR_PROMTAIL" -eq 1 ]]; then
  echo -e "${BLUE}生成 prometheus.runtime.yaml...${NC}"
  "$CONFIG_SCRIPT"
fi

ssh_target() {
  local h="$1"
  [[ "$h" == *@* ]] && echo "$h" || echo "root@${h}"
}

MONITOR_SSH="$(ssh_target "$MONITOR_HOST")"
SERVER_SSH="$(ssh_target "$SERVER_HOST")"

compose_env_args=()
[[ -f "$ENV_FILE" ]] && compose_env_args+=(--env-file "$ENV_FILE")

images_from_compose_files() {
  local f
  for f in "$@"; do
    [[ -f "$DOCKER_DIR/$f" ]] || continue
    docker compose "${compose_env_args[@]}" --project-directory "$DOCKER_DIR" \
      -f "$DOCKER_DIR/$f" config --images 2>/dev/null || true
  done | sort -u
}

check_local_images() {
  local files=()
  [[ "$DO_MONITOR" -eq 1 ]] && files+=("docker-compose-monitor.yaml")
  [[ "$DO_MONITOR" -eq 1 && "$MONITOR_CLUSTER" -eq 1 ]] && files+=("docker-compose-cluster-monitor.yaml")
  [[ "$DO_MONITOR" -eq 1 && "$MONITOR_PROMTAIL" -eq 1 ]] && files+=("docker-compose-promtail.yaml")
  [[ "$DO_SERVER" -eq 1 ]] && files+=("docker-compose-cluster.yaml" "docker-compose-cluster-monitor.yaml" "docker-compose-promtail.yaml" "docker-compose.yaml")
  [[ ${#files[@]} -eq 0 ]] && return 0

  echo -e "${BLUE}检查本机 Docker 镜像(与本次部署相关的 compose)…${NC}"
  local miss=0
  local img
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "  ok  $img"
    else
      echo -e "  ${RED}缺失${NC} $img"
      miss=1
    fi
  done < <(images_from_compose_files "${files[@]}")

  if [[ "$miss" -ne 0 ]]; then
    echo -e "${RED}本机缺少上述镜像, 请先 docker pull / docker load, 或在构建机准备好后再部署。${NC}" >&2
    exit 1
  fi
  echo -e "${GREEN}镜像检查通过${NC}"
}

check_local_images

if [[ "$DO_MONITOR" -eq 1 ]]; then
  echo -e "${BLUE}同步 Monitor -> $MONITOR_SSH:$REMOTE_DEST/docker/${NC}"
  [[ -d "$DOCKER_DIR" ]] || { echo -e "${RED}缺少目录 $DOCKER_DIR${NC}" >&2; exit 1; }
  [[ -d "$PROJECT_DIR/scripts" ]] || { echo -e "${RED}缺少目录 $PROJECT_DIR/scripts${NC}" >&2; exit 1; }
  ssh "$MONITOR_SSH" "mkdir -p '$REMOTE_DEST'"
  scp -r "$DOCKER_DIR" "${MONITOR_SSH}:$REMOTE_DEST/"
  echo -e "${BLUE}同步 Monitor scripts/${NC}"
  scp -r "$PROJECT_DIR/scripts" "${MONITOR_SSH}:$REMOTE_DEST/"
fi

if [[ "$DO_SERVER" -eq 1 ]]; then
  for d in docker scripts tests; do
    [[ -d "$PROJECT_DIR/$d" ]] || {
      echo -e "${RED}缺少目录: $PROJECT_DIR/$d${NC}" >&2
      exit 1
    }
  done
  echo -e "${BLUE}同步 Server -> $SERVER_SSH:$REMOTE_DEST/${NC}"
  ssh "$SERVER_SSH" "mkdir -p '$REMOTE_DEST'"
  scp -r "$PROJECT_DIR/config" "$PROJECT_DIR/docker" "$PROJECT_DIR/scripts" "$PROJECT_DIR/tests" "${SERVER_SSH}:$REMOTE_DEST/"
fi

# 仅当 -p 但未选择 -s 时,仍需给 Server 提前下发 docker/,否则无法执行 promtail compose
if [[ "$MONITOR_PROMTAIL" -eq 1 && "$DO_SERVER" -eq 0 ]]; then
  echo -e "${BLUE}同步 Server docker/ (供 promtail compose) -> $SERVER_SSH:$REMOTE_DEST/docker/${NC}"
  [[ -d "$DOCKER_DIR" ]] || { echo -e "${RED}缺少目录 $DOCKER_DIR${NC}" >&2; exit 1; }
  ssh "$SERVER_SSH" "mkdir -p '$REMOTE_DEST'"
  scp -r "$DOCKER_DIR" "${SERVER_SSH}:$REMOTE_DEST/"
fi

if [[ "$REMOTE_RUN" -eq 1 ]]; then
  if [[ "$DO_MONITOR" -eq 1 ]]; then
    monitor_run_args=()
    [[ "$MONITOR_CLUSTER" -eq 1 ]] && monitor_run_args+=(--cluster)
    echo -e "${BLUE}远端 Monitor 执行 run_monitor.sh ${monitor_run_args[*]} …${NC}"
    ssh "$MONITOR_SSH" "bash '$REMOTE_DEST/scripts/run_monitor.sh' ${monitor_run_args[*]}"
  fi
  if [[ "$DO_SERVER" -eq 1 ]]; then
    if [[ "$SERVER_RUN_KIND" == "cluster" ]]; then
      echo -e "${BLUE}远端 Server 执行 run_cluster.sh …${NC}"
      ssh "$SERVER_SSH" "bash '$REMOTE_DEST/scripts/run_cluster.sh'"
    else
      echo -e "${BLUE}远端 Server 执行 run_docker.sh …${NC}"
      ssh "$SERVER_SSH" "bash '$REMOTE_DEST/scripts/run_docker.sh'"
    fi
  fi
  if [[ "$MONITOR_PROMTAIL" -eq 1 ]]; then
    echo -e "${BLUE}检查 Server 侧 promtail compose 文件...${NC}"
    ssh "$SERVER_SSH" "test -f '$REMOTE_DEST/docker/docker-compose-promtail.yaml' && test -f '$REMOTE_DEST/docker/promtail.yaml'"
    echo -e "${BLUE}连接 Server 执行 promtail compose(up -d) …${NC}"
    ssh "$SERVER_SSH" "cd '$REMOTE_DEST/docker' && docker compose -p aikv-promtail -f docker-compose-promtail.yaml --project-directory '$REMOTE_DEST/docker' up -d"
  fi
fi

echo -e "${GREEN}完成${NC}"
