#!/bin/bash

# 运行 AiKv Docker 镜像
#
# 用法：
#   ./run_docker.sh               # 运行 aikv:latest
#   ./run_docker.sh -t myimage:v1 # 指定镜像
#   ./run_docker.sh --stop        # 停止容器
#   ./run_docker.sh --help        # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

# 默认值
IMAGE_NAME="aikv:latest"
CONTAINER_NAME="aikv"

# 解析参数
ACTION="start"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --help|-h)
            echo "用法: $0 [-t IMAGE] [--stop]"
            echo ""
            echo "参数:"
            echo "  -t IMAGE  镜像名和标签 (默认: aikv:latest)"
            echo "  --stop    停止容器"
            echo ""
            echo "示例:"
            echo "  $0               # 运行 aikv:latest"
            echo "  $0 -t myimage:v1 # 运行自定义镜像"
            echo "  $0 --stop        # 停止容器"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ "$ACTION" == "stop" ]]; then
    echo "停止容器..."
    docker compose -p aikv -f "$DOCKER_DIR/docker-compose.yaml" down -v --remove-orphans
    echo "已停止"
    exit 0
fi

# 确保数据目录存在
mkdir -p "$PROJECT_DIR/data"

# 清理旧容器和网络（确保环境干净）
echo "清理旧环境..."
docker compose -p aikv -f "$DOCKER_DIR/docker-compose.yaml" down -v --remove-orphans 2>/dev/null || true
rm -rf "$PROJECT_DIR/data/aikv"/*

# 检查镜像是否存在
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "错误: 镜像 $IMAGE_NAME 不存在"
    echo "请先运行 ./scripts/build_docker.sh 构建镜像"
    exit 1
fi

# 启动容器
echo "启动 AiKv..."
docker compose -p aikv -f "$DOCKER_DIR/docker-compose.yaml" up -d

echo ""
echo "=== 启动成功 ==="

# 执行功能测试脚本
"$PROJECT_DIR/tests/test_functional.sh"