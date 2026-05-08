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
#   ./build_docker.sh --fresh             # 全量重建: 清 Docker 构建缓存 + cargo 挂载缓存
#   ./build_docker.sh --verify            # 仅验证已有镜像(不构建), 用 grep 检查特征字符串
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
FRESH_BUILD=false
VERIFY_ONLY=false

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
        --fresh)
            FRESH_BUILD=true
            NO_CACHE_FLAG="--no-cache"
            shift
            ;;
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        --help|-h)
            echo "用法: $0 [-t IMAGE] [--release|--dev] [--cluster] [--no-cache] [--fresh] [--verify]"
            echo ""
            echo "参数:"
            echo "  -t IMAGE     镜像名和标签 (默认: aikv:latest; --cluster 默认 aikv:cluster; --dev 默认 aikv:dev)"
            echo "  --release    显式使用 release 编译( 默认) "
            echo "  --dev        debug 编译, Docker 构建快很多, 适合频繁改代码"
            echo "  --cluster    启用集群 feature"
            echo "  --no-cache   不使用镜像构建缓存( 等价于 docker build --no-cache) "
            echo "  --fresh      全量重建: 额外清除 BuildKit cache-mount( cargo registry/git)"
            echo "                确保路径依赖(AiDb)无任何残留编译产物, 推荐怀疑缓存问题时使用"
            echo "  --verify     不构建, 验证已有镜像是否包含预期的代码字符串"
            echo ""
            echo "示例:"
            echo "  $0                        # aikv:latest"
            echo "  $0 --cluster              # aikv:cluster"
            echo "  $0 --dev --cluster        # aikv:dev, 集群 + debug"
            echo "  $0 --dev --cluster --fresh  # 全量重建集群镜像, 最彻底的构建"
            echo "  $0 -t myimage:v1         # 自定义镜像名"
            echo "  $0 --release --cluster   # release + 集群"
            echo "  $0 --verify               # 验证 aikv:cluster 镜像"
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

# ---- Verify mode ----
if $VERIFY_ONLY; then
    echo "=== 验证镜像: $IMAGE_NAME ==="
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "错误: 镜像不存在: $IMAGE_NAME"
        exit 1
    fi
    echo "镜像构建时间: $(docker image inspect "$IMAGE_NAME" --format '{{.Created}}' 2>/dev/null)"
    echo "二进制包含 'failover_repair': $(docker run --rm --entrypoint sh "$IMAGE_NAME" -c "cat /app/aikv 2>/dev/null | tr -d '\0' | grep -c 'failover_repair' || echo 0")"
    echo "二进制包含 'ensure_group_initialized': $(docker run --rm --entrypoint sh "$IMAGE_NAME" -c "cat /app/aikv 2>/dev/null | tr -d '\0' | grep -c 'ensure_group_initialized' || echo 0")"
    echo "=== 验证完成 ==="
    exit 0
fi

# ---- Fresh mode: 清 BuildKit mount cache (cargo registry/git 残留) ----
if $FRESH_BUILD; then
    echo "=== 清除 BuildKit 挂载缓存 (cargo registry/git) ==="
    docker builder prune --all -f 2>/dev/null || true
    docker system prune -f 2>/dev/null || true
    # cargo 的 target 目录产物也清掉, 确保本地增量编译检测从零开始
    rm -rf "$PROJECT_DIR/../AiKv/target" 2>/dev/null || true
    rm -rf "$PROJECT_DIR/../AiDb/target" 2>/dev/null || true
    echo "缓存已清除"
fi

echo "=== 构建 Docker 镜像 (本地 AiDb) ==="
echo "镜像名: $IMAGE_NAME"
echo "配置: PROFILE=${PROFILE_ARGS:---build-arg PROFILE=release} FEATURES=${FEATURES:---build-arg FEATURES=} ${NO_CACHE_FLAG:+--no-cache}"

export DOCKER_BUILDKIT=1

docker build \
    -t "$IMAGE_NAME" \
    -f docker/Dockerfile \
    $NO_CACHE_FLAG \
    $FEATURES \
    $PROFILE_ARGS \
    ..

echo ""
echo "=== 构建完成 ==="

# 自动验证
echo "=== 快速验证 ==="
r1=$(docker run --rm --entrypoint sh "$IMAGE_NAME" -c "cat /app/aikv 2>/dev/null | tr -d '\0' | grep -c 'failover_repair' || echo 0" 2>/dev/null)
r2=$(docker run --rm --entrypoint sh "$IMAGE_NAME" -c "cat /app/aikv 2>/dev/null | tr -d '\0' | grep -c 'ensure_group_initialized' || echo 0" 2>/dev/null)
echo "failover_repair: $r1"
echo "ensure_group_initialized: $r2"
if [ "$r1" = "0" ] || [ "$r2" = "0" ]; then
    echo "警告: 部分特征字符串未找到, 如果是预期的新代码请忽略; 否则可尝试 --fresh 重新构建"
fi
echo "=== 验证完成 ==="

