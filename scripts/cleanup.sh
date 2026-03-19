#!/bin/bash

# AiKv 环境清理脚本 - 清理所有相关资源

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

echo "  AiKv 环境清理"

# 确认操作
FORCE=false
if [[ "$1" == "--force" || "$1" == "-f" ]]; then
    FORCE=true
fi

if [[ "$FORCE" != true ]]; then
    read -p "确认清理所有 AiKv 相关资源? (y/N): " confirm
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

echo ""
echo "=== 2. 删除 Docker 镜像 ==="
docker rmi aikv:latest 2>/dev/null || true

echo ""
echo "=== 3. 删除 Docker 网络 ==="
docker network rm aikv-workflow 2>/dev/null || true
docker network rm aikv 2>/dev/null || true

echo ""
echo "=== 4. 删除 Docker 卷 ==="
docker volume rm docker_aikv-data 2>/dev/null || true
docker volume rm aikv_aikv1-data 2>/dev/null || true

echo ""
echo "=== 5. 停止本地进程 ==="
if [[ -f "$PROJECT_DIR/target/aikv.pid" ]]; then
    pid=$(cat "$PROJECT_DIR/target/aikv.pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "已停止 PID: $pid"
    fi
    rm -f "$PROJECT_DIR/target/aikv.pid"
fi
pkill -f "aikv.*target" 2>/dev/null || true

echo ""
echo "=== 6. 清理本地目录 ==="
rm -rf "$PROJECT_DIR/data/aikv"/*
rm -rf "$PROJECT_DIR/logs"/*
rm -rf "$PROJECT_DIR/target"/*
rm -f "$PROJECT_DIR/target/aikv.pid"

echo ""
echo "  清理完成!"
