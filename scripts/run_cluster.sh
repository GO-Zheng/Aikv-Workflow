#!/bin/bash

# 运行 AiKv 集群模式 Docker 镜像 (3主3从)
#
# 用法：
#   ./run_cluster.sh                                  # 启动集群(默认初始化)
#   ./run_cluster.sh --no-init                        # 启动集群(不初始化)
#   ./run_cluster.sh --with-cluster-monitor           # 启动集群 + 集群监控 exporters
#   ./run_cluster.sh --no-init --with-cluster-monitor # 启动(不初始化)+ 监控
#   ./run_cluster.sh --stop                           # 停止集群
#   ./run_cluster.sh --stop --with-cluster-monitor    # 停止集群 + 集群监控
#   ./run_cluster.sh --help                           # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"
CLUSTER_COMPOSE="$DOCKER_DIR/docker-compose-cluster.yaml"
CLUSTER_MONITOR_COMPOSE="$DOCKER_DIR/docker-compose-cluster-monitor.yaml"

# 默认值
ACTION="start"
DO_INIT=true
WITH_CLUSTER_MONITOR=false
IMAGE_NAME="aikv:cluster"
IMAGE_EXPLICIT=false
BOOTSTRAP_CONFIG="$PROJECT_DIR/config/aikv-master-1.toml"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-init)
            DO_INIT=false
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --with-cluster-monitor|-m)
            WITH_CLUSTER_MONITOR=true
            shift
            ;;
        --cluster)
            # 与 build_docker.sh --cluster 产物一致; 若已通过 -t 指定镜像则不覆盖
            if [[ "$IMAGE_EXPLICIT" != "true" ]]; then
                IMAGE_NAME="aikv:cluster"
            fi
            shift
            ;;
        -t)
            IMAGE_NAME="$2"
            IMAGE_EXPLICIT=true
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [--no-init] [--stop] [--with-cluster-monitor] [--cluster] [-t IMAGE]"
            echo ""
            echo "参数:"
            echo "  --no-init                 跳过集群初始化"
            echo "  --stop                    停止集群"
            echo "  --with-cluster-monitor, -m  同时启动/停止集群监控 exporters"
            echo "  --cluster                 使用集群镜像 aikv:cluster(默认即此, 与 -t 互斥于自定义)"
            echo "  -t IMAGE                  镜像名和标签(覆盖默认 aikv:cluster)"
            echo ""
            echo "示例:"
            echo "  $0                                # 启动集群并初始化"
            echo "  $0 --no-init                      # 启动集群(不初始化)"
            echo "  $0 --with-cluster-monitor         # 启动集群 + 集群监控"
            echo "  $0 --no-init --with-cluster-monitor  # 启动(不初始化)+ 监控"
            echo "  $0 --stop                         # 停止集群"
            echo "  $0 --stop --with-cluster-monitor  # 停止集群 + 集群监控"
            echo "  $0 -t myregistry/aikv:v1          # 使用自定义镜像"
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
    docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" --project-directory "$DOCKER_DIR" down -v --remove-orphans 2>/dev/null || true

    if [[ "$WITH_CLUSTER_MONITOR" == "true" ]]; then
        echo "停止集群监控 exporters..."
        docker compose -p aikv-cluster-monitor -f "$CLUSTER_MONITOR_COMPOSE" --project-directory "$DOCKER_DIR" down 2>/dev/null || true
    fi

    echo "已停止"
    exit 0
fi

# 确保数据目录存在
mkdir -p "$PROJECT_DIR/data/aikv-cluster"

# 清理旧容器和网络
echo "清理旧环境..."
docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" --project-directory "$DOCKER_DIR" down -v --remove-orphans 2>/dev/null || true
rm -rf "$PROJECT_DIR/data/aikv-cluster"/*

if [[ "$WITH_CLUSTER_MONITOR" == "true" ]]; then
    docker compose -p aikv-cluster-monitor -f "$CLUSTER_MONITOR_COMPOSE" --project-directory "$DOCKER_DIR" down 2>/dev/null || true
fi

# 检查即将由 compose 使用的镜像是否存在(默认 aikv:cluster, 或由 -t 指定)
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "错误: 集群镜像不存在: $IMAGE_NAME"
    if [[ "$IMAGE_EXPLICIT" == "true" ]]; then
        echo "请构建/拉取该镜像后再运行, 或去掉 -t 使用默认 aikv:cluster"
    else
        echo "请先运行: ./scripts/build_docker.sh --cluster"
    fi
    exit 1
fi

# 初始化前设置 is_bootstrap 为 true
if [[ -f "$BOOTSTRAP_CONFIG" ]]; then
    if grep -q 'is_bootstrap = true' "$BOOTSTRAP_CONFIG"; then
        echo "is_bootstrap 已为 true, 无需修改"
    else
        echo "is_bootstrap 为 false, 修改为 true..."
        sed -i 's/is_bootstrap = false/is_bootstrap = true/' "$BOOTSTRAP_CONFIG"
    fi
else
    echo "警告: 配置文件 $BOOTSTRAP_CONFIG 不存在, 跳过 bootstrap 检查"
fi

# 启动集群容器(与 compose 中 image 一致)
export AIKV_CLUSTER_IMAGE="$IMAGE_NAME"
echo "启动 AiKv 集群(镜像: $AIKV_CLUSTER_IMAGE)..."
docker compose -p aikv-cluster -f "$CLUSTER_COMPOSE" --project-directory "$DOCKER_DIR" up -d

echo ""
echo "=== 集群启动成功 ==="
echo ""
echo "节点:"
echo "  Master-1:  127.0.0.1:6379 (Raft: 50051)"
echo "  Replica-1: 127.0.0.1:6380 (Raft: 50052)"
echo "  Master-2:  127.0.0.1:6381 (Raft: 50053)"
echo "  Replica-2: 127.0.0.1:6382 (Raft: 50054)"
echo "  Master-3:  127.0.0.1:6383 (Raft: 50055)"
echo "  Replica-3: 127.0.0.1:6384 (Raft: 50056)"

# 启动集群监控 exporters
if [[ "$WITH_CLUSTER_MONITOR" == "true" ]]; then
    echo ""
    echo "启动集群监控 exporters..."
    docker compose -p aikv-cluster-monitor -f "$CLUSTER_MONITOR_COMPOSE" --project-directory "$DOCKER_DIR" up -d

    echo ""
    echo "=== 集群监控端口 ==="
    echo "Redis Exporters:"
    echo "  master-1:  127.0.0.1:9121"
    echo "  replica-1: 127.0.0.1:9221"
    echo "  master-2:  127.0.0.1:9321"
    echo "  replica-2: 127.0.0.1:9421"
    echo "  master-3:  127.0.0.1:9521"
    echo "  replica-3: 127.0.0.1:9621"
    echo ""
    echo "Aidb Exporters:"
    echo "  master-1:  127.0.0.1:9120"
    echo "  replica-1: 127.0.0.1:9220"
    echo "  master-2:  127.0.0.1:9320"
    echo "  replica-2: 127.0.0.1:9420"
    echo "  master-3:  127.0.0.1:9520"
    echo "  replica-3: 127.0.0.1:9620"
fi

# 等待节点就绪
echo ""
echo "等待节点就绪..."
sleep 5

# 初始化集群(默认执行)
if [[ "$DO_INIT" == "true" ]]; then
    echo ""
    echo "=== 初始化集群 ==="
    "$SCRIPT_DIR/init_cluster.sh"

    # 初始化完成后, 将 is_bootstrap 改回 false
    if [[ -f "$BOOTSTRAP_CONFIG" ]]; then
        echo ""
        echo "初始化完成, 设置 is_bootstrap 为 false..."
        sed -i 's/is_bootstrap = true/is_bootstrap = false/' "$BOOTSTRAP_CONFIG"
    fi

    echo ""
    echo "=== 运行集群功能测试 ==="
    if "$PROJECT_DIR/tests/test_cluster_functional.sh"; then
        echo ""
        echo "=== 功能测试通过 ==="
    else
        echo ""
        echo "=== 功能测试失败 ==="
        exit 1
    fi
else
    echo "跳过集群初始化。如需手动初始化, 请运行:"
    echo "  ./scripts/init_cluster.sh"
fi