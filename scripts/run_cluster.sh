#!/bin/bash

# 运行 AiKv 集群模式 Docker 镜像 (3主3从)
#
# 用法：
#   ./run_cluster.sh         # 启动集群
#   ./run_cluster.sh --init  # 启动并初始化集群
#   ./run_cluster.sh --stop  # 停止集群
#   ./run_cluster.sh --help  # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"
CLUSTER_COMPOSE="$DOCKER_DIR/docker-compose-cluster.yaml"

# 默认值
ACTION="start"
DO_INIT=false
IMAGE_NAME="aikv:latest"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --init)
            DO_INIT=true
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        -t)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [--init] [--stop] [-t IMAGE]"
            echo ""
            echo "参数:"
            echo "  --init   启动后初始化集群"
            echo "  --stop   停止集群"
            echo "  -t IMAGE 镜像名和标签 (默认: aikv:latest)"
            echo ""
            echo "示例:"
            echo "  $0                    # 启动集群"
            echo "  $0 --init            # 启动并初始化"
            echo "  $0 --stop            # 停止集群"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ "$ACTION" == "stop" ]]; then
    echo "停止集群..."
    docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" down -v --remove-orphans
    echo "已停止"
    exit 0
fi

# 确保数据目录存在
mkdir -p "$PROJECT_DIR/data/aikv-cluster"

# 清理旧容器和网络
echo "清理旧环境..."
docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" down -v --remove-orphans 2>/dev/null || true

# 检查镜像是否存在
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "错误: 镜像 $IMAGE_NAME 不存在"
    echo "请先运行 ./scripts/build_docker.sh --cluster 构建镜像"
    exit 1
fi

# 启动集群容器
echo "启动 AiKv 集群..."
docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" up -d

echo ""
echo "=== 集群启动成功 ==="
echo ""
echo "节点:"
echo "  Master  1: 127.0.0.1:6379"
echo "  Replica 1: 127.0.0.1:6380"
echo "  Master  2: 127.0.0.1:6381"
echo "  Replica 2: 127.0.0.1:6382"
echo "  Master  3: 127.0.0.1:6383"
echo "  Replica 3: 127.0.0.1:6384"
echo ""

# 等待节点就绪
echo "等待节点就绪..."
sleep 5

# 初始化集群
if [[ "$DO_INIT" == "true" ]]; then
    echo ""
    echo "=== 初始化集群 ==="
    "$SCRIPT_DIR/init_cluster.sh"
else
    echo "如需初始化集群，请运行:"
    echo "  ./scripts/init_cluster.sh"
fi
