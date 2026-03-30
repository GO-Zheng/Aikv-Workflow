#!/bin/bash

# 构建 AiKv Docker 镜像（使用本地 AiDb）
#
# 用法：
#   ./build_docker.sh                     # 构建镜像 (默认 aikv:latest)
#   ./build_docker.sh -t myimage:v1       # 指定镜像名和标签
#   ./build_docker.sh --release           # 构建 release 镜像
#   ./build_docker.sh --cluster           # 构建集群模式镜像
#   ./build_docker.sh --release --cluster # 构建 release + 集群
#   ./build_docker.sh --help              # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 解析参数
FEATURES=""
BUILD_OPTS=""
IMAGE_TAG="latest"
CUSTOM_IMAGE_NAME=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)
            IMAGE_TAG="$2"
            CUSTOM_IMAGE_NAME=true
            shift 2
            ;;
        --release)
            BUILD_OPTS="--release"
            shift
            ;;
        --cluster)
            FEATURES="--build-arg FEATURES=cluster"
            if [[ "$CUSTOM_IMAGE_NAME" == "false" ]]; then
                IMAGE_TAG="cluster"
            fi
            shift
            ;;
        --help|-h)
            echo "用法: $0 [-t IMAGE] [--release] [--cluster]"
            echo ""
            echo "参数:"
            echo "  -t IMAGE     镜像名和标签 (默认: aikv:latest, 集群模式默认: aikv:cluster)"
            echo "  --release    生产优化模式"
            echo "  --cluster    启用集群模式"
            echo ""
            echo "示例:"
            echo "  $0                        # aikv:latest"
            echo "  $0 --cluster              # aikv:cluster"
            echo "  $0 -t myimage:v1         # 自定义镜像名"
            echo "  $0 --release             # release 镜像"
            echo "  $0 --release --cluster   # release + 集群"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

IMAGE_NAME="aikv:${IMAGE_TAG}"

cd "$PROJECT_DIR"

echo "=== 构建 Docker 镜像 (本地 AiDb) ==="
echo "镜像名: $IMAGE_NAME"

# 构建上下文设为 Flow 目录（/root/code/Flow）
# Dockerfile 中使用 ../AiDb 和 ../AiKv 会正确解析到 /root/code/Flow/AiDb 和 /root/code/Flow/AiKv
docker build \
    -t "$IMAGE_NAME" \
    -f docker/Dockerfile \
    $FEATURES \
    ..

echo ""
echo "=== 构建完成 ==="

