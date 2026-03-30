#!/bin/bash

# AiKv 环境清理脚本
#
# 用法：
#   ./cleanup.sh                   # 清理单机 AiKv
#   ./cleanup.sh --cluster         # 清理集群 AiKv
#   ./cleanup.sh --cluster-monitor # 清理集群监控 exporters
#   ./cleanup.sh --all             # 清理全部（包括单机 monitor）
#   ./cleanup.sh --force           # 跳过确认

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

CLEAN_SINGLE=false
CLEAN_CLUSTER=false
CLEAN_CLUSTER_MONITOR=false
CLEAN_ALL=false
FORCE=false

# 解析参数
for arg in "$@"; do
    case "$arg" in
        --single|-s)
            CLEAN_SINGLE=true
            ;;
        --cluster|-c)
            CLEAN_CLUSTER=true
            ;;
        --cluster-monitor|-m)
            CLEAN_CLUSTER_MONITOR=true
            ;;
        --all|-a)
            CLEAN_ALL=true
            ;;
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "用法: $0 [OPTIONS]"
            echo ""
            echo "参数:"
            echo "  --single, -s        清理单机 AiKv"
            echo "  --cluster, -c       清理集群 AiKv"
            echo "  --cluster-monitor, -m 清理集群监控 exporters"
            echo "  --all, -a           清理全部（包括单机 monitor）"
            echo "  --force, -f         跳过确认提示"
            echo ""
            echo "示例:"
            echo "  $0                      # 清理单机 AiKv"
            echo "  $0 --cluster            # 清理集群 AiKv"
            echo "  $0 --cluster-monitor    # 清理集群监控"
            echo "  $0 --all                # 清理全部"
            exit 0
            ;;
    esac
done

# 默认清理单机
if [[ "$CLEAN_SINGLE" == "false" && "$CLEAN_CLUSTER" == "false" && "$CLEAN_CLUSTER_MONITOR" == "false" && "$CLEAN_ALL" == "false" ]]; then
    CLEAN_SINGLE=true
fi

# 确认操作
if [[ "$FORCE" != true ]]; then
    echo "确认清理? (y/N): "
    read confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "取消清理"
        exit 0
    fi
fi

# 清理单机 AiKv
if [[ "$CLEAN_SINGLE" == "true" ]]; then
    echo "=== 清理单机 AiKv ==="
    docker compose -p aikv -f "$DOCKER_DIR/docker-compose.yaml" down -v --remove-orphans 2>/dev/null || true
    docker stop aikv 2>/dev/null || true
    docker rm aikv 2>/dev/null || true
    rm -rf "$PROJECT_DIR/data/aikv"/*
fi

# 清理集群 AiKv
if [[ "$CLEAN_CLUSTER" == "true" ]]; then
    echo "=== 清理集群 AiKv ==="
    docker compose -p aikv-cluster -f "$DOCKER_DIR/docker-compose-cluster.yaml" down -v --remove-orphans 2>/dev/null || true
    rm -rf "$PROJECT_DIR/data/aikv-cluster"/*
fi

# 清理集群监控 exporters
if [[ "$CLEAN_CLUSTER_MONITOR" == "true" ]]; then
    echo "=== 清理集群监控 exporters ==="
    docker compose -p aikv-cluster-monitor -f "$DOCKER_DIR/docker-compose-cluster-monitor.yaml" down 2>/dev/null || true
fi

# 清理全部（包括单机 monitor）
if [[ "$CLEAN_ALL" == "true" ]]; then
    echo "=== 清理全部 (包括 Monitor) ==="
    docker compose -p aikv -f "$DOCKER_DIR/docker-compose.yaml" down -v --remove-orphans 2>/dev/null || true
    docker compose -p aikv-cluster -f "$DOCKER_DIR/docker-compose-cluster.yaml" down -v --remove-orphans 2>/dev/null || true
    docker compose -p aikv-cluster-monitor -f "$DOCKER_DIR/docker-compose-cluster-monitor.yaml" down 2>/dev/null || true
    docker compose -p aikv-monitor -f "$DOCKER_DIR/docker-compose-monitor.yaml" down -v --remove-orphans 2>/dev/null || true
    docker stop aikv 2>/dev/null || true
    docker rm aikv 2>/dev/null || true
    rm -rf "$PROJECT_DIR/data/aikv"/*
    rm -rf "$PROJECT_DIR/data/aikv-cluster"/*
    rm -rf "$PROJECT_DIR/logs"/*
    rm -rf "$PROJECT_DIR/data/prometheus"/*
    rm -rf "$PROJECT_DIR/data/grafana"/*
fi

# 清理网络（如果没被使用）
cleanup_network() {
    local network=$1
    local count=$(docker network inspect "$network" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [[ "$count" == "0" ]]; then
        docker network rm "$network" 2>/dev/null || true
    fi
}

cleanup_network aikv-workflow

echo ""
echo "清理完成!"