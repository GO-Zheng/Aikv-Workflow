#!/bin/bash

# AiKv 环境清理脚本
# 默认只清理 AiKv 相关资源
# 使用 --all 参数清理所有资源（包括 monitor）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

CLEAN_ALL=false
FORCE=false

# 解析参数
for arg in "$@"; do
    case "$arg" in
        --all|-a)
            CLEAN_ALL=true
            ;;
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "用法: $0 [--all] [--force]"
            echo "  --all, -a   清理所有资源（包括 monitor）"
            echo "  --force, -f 跳过确认提示"
            exit 0
            ;;
    esac
done

if [[ "$CLEAN_ALL" == true ]]; then
    echo "  AiKv 环境清理（全部）"
else
    echo "  AiKv 环境清理（仅 AiKv）"
fi

# 确认操作
if [[ "$FORCE" != true ]]; then
    if [[ "$CLEAN_ALL" == true ]]; then
        read -p "确认清理所有 AiKv 和 Monitor 相关资源? (y/N): " confirm
    else
        read -p "确认清理 AiKv 相关资源（Monitor 保留）? (y/N): " confirm
    fi
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "取消清理"
        exit 0
    fi
fi

echo ""
echo "=== 1. 停止 Docker 容器 ==="
docker compose -f "$DOCKER_DIR/docker-compose.yaml" down -v --remove-orphans 2>/dev/null || true
docker stop aikv 2>/dev/null || true
docker rm aikv 2>/dev/null || true

if [[ "$CLEAN_ALL" == true ]]; then
    docker compose -f "$DOCKER_DIR/docker-compose-monitor.yaml" down -v --remove-orphans 2>/dev/null || true
    docker stop prometheus 2>/dev/null || true
    docker rm prometheus 2>/dev/null || true
    docker stop grafana 2>/dev/null || true
    docker rm grafana 2>/dev/null || true
fi

echo ""
echo "=== 2. 删除 Docker 网络 ==="
# 检查网络是否被使用，只清理未使用的网络
cleanup_network() {
    local network=$1
    # 查询使用该网络的容器数量
    local count=$(docker network inspect "$network" --format '{{len .Containers}}' 2>/dev/null || echo "0")
    if [[ "$count" == "0" ]]; then
        docker network rm "$network" 2>/dev/null || true
    else
        echo "跳过 $network（仍有 $count 个容器在使用）"
    fi
}

cleanup_network aikv-workflow
cleanup_network aikv

if [[ "$CLEAN_ALL" == true ]]; then
    cleanup_network monitor
fi

echo ""
echo "=== 3. 删除 Docker 卷 ==="
docker volume rm docker_aikv-data 2>/dev/null || true
docker volume rm aikv_aikv1-data 2>/dev/null || true

if [[ "$CLEAN_ALL" == true ]]; then
    docker volume rm docker_prometheus-data 2>/dev/null || true
    docker volume rm docker_grafana-data 2>/dev/null || true
fi

echo ""
echo "=== 4. 停止本地进程 ==="
if [[ -f "$PROJECT_DIR/target/aikv.pid" ]]; then
    pid=$(cat "$PROJECT_DIR/target/aikv.pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "已停止 PID: $pid"
    fi
    rm -f "$PROJECT_DIR/target/aikv.pid"
fi
pkill -f "aikv.*target" 2>/dev/null || true

if [[ "$CLEAN_ALL" == true ]]; then
    pkill -f "prometheus" 2>/dev/null || true
    pkill -f "grafana" 2>/dev/null || true
fi

echo ""
echo "=== 5. 清理本地目录 ==="
rm -rf "$PROJECT_DIR/data/aikv"/*
rm -rf "$PROJECT_DIR/target"/*
rm -f "$PROJECT_DIR/target/aikv.pid"

if [[ "$CLEAN_ALL" == true ]]; then
    rm -rf "$PROJECT_DIR/logs"/*
    rm -rf "$PROJECT_DIR/data/prometheus"/*
    rm -rf "$PROJECT_DIR/data/grafana"/*
fi

echo ""
echo "  清理完成!"
