#!/bin/bash

# 构建 AiKv Docker 镜像( 使用本地 AiDb) 
#
# 用法：
#   ./build_docker.sh                     # 构建镜像 (默认 aikv:latest)
#   ./build_docker.sh -t myimage:v1       # 指定镜像名和标签
#   ./build_docker.sh --release           # 显式 release(默认已是 release, 可省略) 
#   ./build_docker.sh --dev               # debug 编译, 迭代远快于 release(调试用) 
#   ./build_docker.sh --cluster           # 构建集群模式镜像
#   ./build_docker.sh --dev --cluster     # 集群 + debug, 日常改代码首选
#   ./build_docker.sh --no-cache          # 禁用镜像层缓存, 干净全量构建
#   ./build_docker.sh --help              # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 解析参数
FEATURES=""
PROFILE_ARGS=""
IMAGE_TAG="latest"
CUSTOM_IMAGE_NAME=false
NO_CACHE_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)
            IMAGE_TAG="$2"
            CUSTOM_IMAGE_NAME=true
            shift 2
            ;;
        --release)
            PROFILE_ARGS="--build-arg PROFILE=release"
            shift
            ;;
        --dev)
            PROFILE_ARGS="--build-arg PROFILE=dev"
            if [[ "$CUSTOM_IMAGE_NAME" == "false" ]]; then
                IMAGE_TAG="dev"
            fi
            shift
            ;;
        --cluster)
            FEATURES="--build-arg FEATURES=cluster"
            if [[ "$CUSTOM_IMAGE_NAME" == "false" ]]; then
                IMAGE_TAG="cluster"
            fi
            shift
            ;;
        --no-cache)
            NO_CACHE_FLAG="--no-cache"
            shift
            ;;
        --help|-h)
            echo "用法: $0 [-t IMAGE] [--release|--dev] [--cluster] [--no-cache]"
            echo ""
            echo "参数:"
            echo "  -t IMAGE     镜像名和标签 (默认: aikv:latest; --cluster 默认 aikv:cluster; --dev 默认 aikv:dev)"
            echo "  --release    显式使用 release 编译( 默认) "
            echo "  --dev        debug 编译, Docker 构建快很多, 适合频繁改代码"
            echo "  --cluster    启用集群 feature"
            echo "  --no-cache   不使用镜像构建缓存( 等价于 docker build --no-cache) "
            echo ""
            echo "示例:"
            echo "  $0                        # aikv:latest"
            echo "  $0 --cluster              # aikv:cluster"
            echo "  $0 --dev --cluster        # aikv:dev, 集群 + debug"
            echo "  $0 -t myimage:v1         # 自定义镜像名"
            echo "  $0 --release --cluster   # release + 集群"
            echo "  $0 --no-cache            # 全量重建, 排查缓存问题时用"
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

# 需要 BuildKit(缓存挂载与 syntax 解析) ; 现代 Docker 默认已开启
export DOCKER_BUILDKIT=1

# 构建上下文为 Aikv-Workflow 的父目录(含 AiDb / AiKv) 
# Dockerfile 中 ../AiDb、../AiKv 相对于该上下文
docker build \
    -t "$IMAGE_NAME" \
    -f docker/Dockerfile \
    $NO_CACHE_FLAG \
    $FEATURES \
    $PROFILE_ARGS \
    ..

echo ""
echo "=== 构建完成 ==="

