#!/usr/bin/env bash
# 生成 Prometheus 运行时配置:
#   docker/prometheus.yaml -> docker/prometheus.runtime.yaml
# 变量来源: docker/.env (MONITOR_HOST, SERVER_HOST)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"
ENV_FILE="$DOCKER_DIR/.env"
SRC_FILE="$DOCKER_DIR/prometheus.yaml"
DST_FILE="$DOCKER_DIR/prometheus.runtime.yaml"

if [[ ! -f "$SRC_FILE" ]]; then
  echo "缺少源文件: $SRC_FILE" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "缺少环境文件: $ENV_FILE（请先复制 .env.example）" >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "未找到 envsubst，请先安装 gettext-base" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${MONITOR_HOST:?请在 docker/.env 中设置 MONITOR_HOST}"
: "${SERVER_HOST:?请在 docker/.env 中设置 SERVER_HOST}"

envsubst '${MONITOR_HOST} ${SERVER_HOST}' <"$SRC_FILE" >"$DST_FILE"
echo "已生成: $DST_FILE"
