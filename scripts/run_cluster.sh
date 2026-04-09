#!/bin/bash

# 运行 AiKv 集群模式 Docker 镜像 (2 主 4 从，每分片 1 主 2 从)
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

# 从 docker/.env 加载环境变量(仅当当前环境未定义时)
load_env_file() {
    local env_file="$DOCKER_DIR/.env"
    if [[ -f "$env_file" ]]; then
        local existing_server_host="${SERVER_HOST-}"
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
        if [[ -n "$existing_server_host" ]]; then
            SERVER_HOST="$existing_server_host"
        fi
    fi
}

build_cluster_nodes_from_host() {
    local host="$1"
    CLUSTER_MASTERS="${host}:6379,${host}:6382"
    CLUSTER_REPLICAS="${host}:6380,${host}:6381,${host}:6383,${host}:6384"
}

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
            echo ""
            echo "若手动执行 docker compose: 必须与脚本使用相同 project 名, 否则 down 删不掉本脚本创建的容器,"
            echo "  随后 up 会报 container name already in use。推荐停止用:"
            echo "  $0 --stop"
            echo "或在 Aikv-Workflow 目录执行:"
            echo "  docker compose -p aikv-cluster -f docker/docker-compose-cluster.yaml --project-directory docker down -v --remove-orphans"
            echo ""
            echo "环境变量:"
            echo "  AIKV_CLUSTER_READY_SECONDS  启动后等待 bootstrap 可 PING 的超时秒数(默认 180)"
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
# 强制删除可能残留的同名容器（无论属于哪个 compose project）
for c in aikv-master-1 aikv-master-2 aikv-replica-1a aikv-replica-1b aikv-replica-2a aikv-replica-2b; do
    docker rm -f "$c" 2>/dev/null || true
done
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
echo "  Master-1:    127.0.0.1:6379 (Raft: 50051)"
echo "  Replica-1a:  127.0.0.1:6380 (Raft: 50052)"
echo "  Replica-1b:  127.0.0.1:6381 (Raft: 50053)"
echo "  Master-2:    127.0.0.1:6382 (Raft: 50054)"
echo "  Replica-2a:  127.0.0.1:6383 (Raft: 50055)"
echo "  Replica-2b:  127.0.0.1:6384 (Raft: 50056)"

# 启动集群监控 exporters
if [[ "$WITH_CLUSTER_MONITOR" == "true" ]]; then
    echo ""
    echo "启动集群监控 exporters..."
    docker compose -p aikv-cluster-monitor -f "$CLUSTER_MONITOR_COMPOSE" --project-directory "$DOCKER_DIR" up -d

    echo ""
    echo "=== 集群监控端口 ==="
    echo "（master-1 的 9121/9120 由主监控栈 aikv-exporter/aidb-exporter 提供；"
    echo " 若本机未起主监控栈，请用 ./scripts/run_monitor.sh -c 或自行暴露 9121/9120）"
    echo "Redis Exporters:"
    echo "  master-1:    127.0.0.1:9121"
    echo "  replica-1a:  127.0.0.1:9221"
    echo "  replica-1b:  127.0.0.1:9321"
    echo "  master-2:    127.0.0.1:9421"
    echo "  replica-2a:  127.0.0.1:9521"
    echo "  replica-2b:  127.0.0.1:9621"
    echo ""
    echo "Aidb Exporters:"
    echo "  master-1:    127.0.0.1:9120"
    echo "  replica-1a:  127.0.0.1:9220"
    echo "  replica-1b:  127.0.0.1:9320"
    echo "  master-2:    127.0.0.1:9420"
    echo "  replica-2a:  127.0.0.1:9520"
    echo "  replica-2b:  127.0.0.1:9620"
fi

# 等待节点就绪
echo ""
echo "等待节点就绪..."
sleep 5

# 初始化集群(默认执行)
if [[ "$DO_INIT" == "true" ]]; then
    load_env_file

    # AiKv 主流程：先 await initialize_cluster()，完成后才在 run() 里 TcpListener::bind。
    # 因此容器已「Started」后的数秒～数分钟内，宿主机 6379 仍可能 Connection refused，并非 hairpin/init 脚本坏了。
    BOOT_WAIT_HOST="127.0.0.1"
    if [[ -n "${SERVER_HOST:-}" ]] && timeout 2 redis-cli -h "$SERVER_HOST" -p 6379 ping 2>/dev/null | grep -q PONG; then
        BOOT_WAIT_HOST="$SERVER_HOST"
    fi
    READY_WAIT="${AIKV_CLUSTER_READY_SECONDS:-180}"
    echo ""
    echo "等待 bootstrap 监听 ${BOOT_WAIT_HOST}:6379（最多 ${READY_WAIT}s，可调环境变量 AIKV_CLUSTER_READY_SECONDS）..."
    _ready=0
    for ((_i = 0; _i < READY_WAIT; _i++)); do
        if redis-cli -h "$BOOT_WAIT_HOST" -p 6379 ping 2>/dev/null | grep -q PONG; then
            echo "Bootstrap 已就绪: ${BOOT_WAIT_HOST}:6379（等待了 ${_i}s）"
            _ready=1
            break
        fi
        if ((_i % 30 == 0)) && ((_i > 0)); then
            echo "  仍在等待 ${BOOT_WAIT_HOST}:6379 ... ${_i}/${READY_WAIT}s"
        fi
        sleep 1
    done
    if [[ "$_ready" != "1" ]]; then
        echo "错误: ${READY_WAIT}s 内 ${BOOT_WAIT_HOST}:6379 仍无 PONG。"
        echo "含义: 进程尚未执行到 Redis 监听（卡在 initialize_cluster）、或反复崩溃退出。"
        echo ""
        echo "=== aikv-master-1 容器状态 ==="
        docker ps -a --filter name=aikv-master-1 --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
        echo ""
        echo "=== docker logs aikv-master-1（最后 120 行）==="
        docker logs aikv-master-1 --tail 120 2>&1 || true
        exit 1
    fi

    echo ""
    echo "=== 初始化集群 ==="
    if [[ -n "${SERVER_HOST:-}" ]]; then
        build_cluster_nodes_from_host "$SERVER_HOST"
        echo "检测到 SERVER_HOST=$SERVER_HOST，使用该地址初始化集群..."
        INIT_CONNECT_HOST=""
        if ! timeout 3 redis-cli -h "$SERVER_HOST" -p 6379 ping 2>/dev/null | grep -q PONG; then
            INIT_CONNECT_HOST="127.0.0.1"
            echo "提示: 本机无法通过 ${SERVER_HOST}:6379 访问（常见于在 SERVER 上用局域网 IP 访问 Docker 端口映射 / hairpin）。"
            echo "      将用 CLUSTER_REDIS_CONNECT_HOST=127.0.0.1 连各端口；CLUSTER MEET 仍使用 ${SERVER_HOST}，外网 redis-cli -c 不受影响。"
        fi
        # 显式 export，避免个别 shell/包装下前缀赋值未传入子进程
        if [[ -n "$INIT_CONNECT_HOST" ]]; then
            export CLUSTER_REDIS_CONNECT_HOST="$INIT_CONNECT_HOST"
        else
            unset CLUSTER_REDIS_CONNECT_HOST 2>/dev/null || true
        fi
        "$SCRIPT_DIR/init_cluster.sh" -m "$CLUSTER_MASTERS" -r "$CLUSTER_REPLICAS"
        unset CLUSTER_REDIS_CONNECT_HOST 2>/dev/null || true
    else
        echo "未检测到 SERVER_HOST，使用 init_cluster.sh 默认地址(127.0.0.1)..."
        "$SCRIPT_DIR/init_cluster.sh"
    fi

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