#!/bin/bash
#
# 先扩容（新 master 入群、无槽），再把 **部分槽** 从已有 master 迁到新 master（复用 test_cluster_migration.sh）。
#
# 用法:
#   ./test_cluster_expand_and_migrate.sh [host] [bootstrap_port] [new_master_port] [new_master_raft_addr] [migrate_src_port]
#
# - migrate_src_port: 作为迁移 **源** 的 Redis 端口（默认同 bootstrap_port，即从第一个分片迁槽到新节点）
# - 新 master 同时作为 test_cluster_migration.sh 的 **目标** 端口
#
# 示例:
#   ./test_cluster_expand_and_migrate.sh 127.0.0.1 6379 6385 aikv-master-3:50051
#   ./test_cluster_expand_and_migrate.sh 192.168.1.113 6379 6385 aikv-master-3:50051 6379
#
# 前置条件:
#   - 新 master 进程/容器已启动且可 PING；compose 须把 NEW_RAFT 解析到正确 gRPC 地址
#   - 本机默认（127.0.0.1 + NEW_PORT=6385）时，test_cluster_expand_master.sh 会按需 docker compose 启动
#     docker/docker-compose-expand.yaml（须先有 docker-compose-cluster 创建的 aikv-workflow 网络）
#   - 与 test_cluster_migration.sh 相同：需安装 redis-cli
#
# 环境变量: 同 test_cluster_expand_master.sh / test_cluster_migration.sh（CLUSTER_REDIS_CONNECT_HOST、IMPORTING_WAIT_MS、
#   AIKV_EXPAND_SKIP_DOCKER 等）
#
# MIGRATE 目标: 默认从 NEW_RAFT 解析出 Docker 主机名并设 MIGRATE_DST_HOST、MIGRATE_DST_PORT=6379，
# 避免源 master 容器内 MIGRATE 127.0.0.1:宿主机端口 导致 Connection refused。可用环境变量覆盖。

set -e

HOST="${1:-127.0.0.1}"
BOOT_PORT="${2:-6379}"
NEW_PORT="${3:?缺少参数: new_master_redis_port}"
NEW_RAFT="${4:?缺少参数: new_master_raft_addr}"
SRC_PORT="${5:-$BOOT_PORT}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo " 扩容 + 单槽迁移 串联测试"
echo " 扩容: bootstrap=${HOST}:${BOOT_PORT}  new=${HOST}:${NEW_PORT}"
echo " 迁移: src=${HOST}:${SRC_PORT} -> dst=${HOST}:${NEW_PORT}"
echo "=============================================="

"$DIR/test_cluster_expand_master.sh" "${HOST}" "${BOOT_PORT}" "${NEW_PORT}" "${NEW_RAFT}"

info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
info "等待元数据同步…"
sleep 3

# 源 AiKv 在容器内执行 MIGRATE 时须能解析目标；用 compose 服务名 + 容器内 Redis 6379
_r="${NEW_RAFT#http://}"
_r="${_r#https://}"
RAFT_SERVICE_HOST="${_r%%:*}"
if [[ -n "${RAFT_SERVICE_HOST}" && "${RAFT_SERVICE_HOST}" != "${_r}" ]]; then
  export MIGRATE_DST_HOST="${MIGRATE_DST_HOST:-${RAFT_SERVICE_HOST}}"
  export MIGRATE_DST_PORT="${MIGRATE_DST_PORT:-6379}"
  info "MIGRATE 目标（源容器侧）: ${MIGRATE_DST_HOST}:${MIGRATE_DST_PORT}"
else
  info "未从 NEW_RAFT 解析出 host:port，MIGRATE 仍用脚本 HOST/NEW_PORT；若 Connection refused 请设 MIGRATE_DST_HOST/MIGRATE_DST_PORT"
fi

exec "$DIR/test_cluster_migration.sh" "${HOST}" "${SRC_PORT}" "${NEW_PORT}"
