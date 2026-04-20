#!/bin/bash

# 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

# 颜色输出
CYAN="\033[0;36m"
BLUE="\033[0;34m"
GREN="\033[0;32m"
YELO="\033[1;33m"
RED="\033[0;31m"
LIGHTCYAN="\033[1;36m"
NC="\033[0m"

# 日志级别 (10=DEBUG, 20=INFO, 30=WARN, 40=ERROR)
LOG_LEVEL="${LOG_LEVEL:-20}"

# 日志输出
debug()   { [[ $LOG_LEVEL -le 10 ]] && echo -e "${CYAN}[DEBG]${NC} $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREN}[SUCC]${NC} $*"; }
warn()    { echo -e "${YELO}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC} $*" >&2; }

# 标题输出
h1() { info "${LIGHTCYAN}=== $* ===${NC}"; }
h2() { info "${LIGHTCYAN}--- $* ---${NC}"; }

# 使用说明
usage() {
    echo "Usage: $0 [-i|--image] [-c|--cluster] [-m|--monitor] [-d|--dir] [-b|--build]"
    echo "  -i, --image     同步镜像到远程节点"
    echo "  -c, --cluster   使用集群模式部署 (默认: 单节点模式)"
    echo "  -m, --monitor   部署监控节点"
    echo "  -d, --dir       同步文件到远程节点"
    echo "  -b, --build     重新构建 Docker 镜像 (build_docker.sh --dev --cluster)"
    exit 1
}

# 解析命令行参数
SYNC_IMAGES=false
CLUSTER_MODE=false
DEPLOY_MONITOR=false
SYNC_FILES=false
BUILD_IMAGE=false

OPTS=$(getopt -o "icmdb" -l "image,cluster,monitor,dir,build" -n "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    usage
fi

eval set -- "$OPTS"
while true; do
    case "$1" in
        -i|--image)      SYNC_IMAGES=true; shift ;;
        -c|--cluster)    CLUSTER_MODE=true; shift ;;
        -m|--monitor)    DEPLOY_MONITOR=true; shift ;;
        -d|--dir)        SYNC_FILES=true; shift ;;
        -b|--build)      BUILD_IMAGE=true; SYNC_IMAGES=true; shift ;;
        --)              shift; break ;;
        *)               usage ;;
    esac
done

# 确定部署模式
if $CLUSTER_MODE; then
    SERVER_COMPOSE="docker-compose-cluster.yaml"
    IMAGE_NAME="aikv:cluster"
else
    SERVER_COMPOSE="docker-compose.yaml"
    IMAGE_NAME="aikv:latest"
fi

info "部署模式: $(if $CLUSTER_MODE; then echo "${CYAN}集群模式${NC}"; else echo "${CYAN}单节点模式${NC}"; fi)"
info "镜像: ${CYAN}$IMAGE_NAME${NC}"

# 服务节点
SERVER_HOST_1="192.168.1.112"
SERVER_HOST_2="192.168.1.113"

# 监控节点
MONITOR_HOST="192.168.1.115"

# 日志级别
LOG_LEVEL=10

# 镜像列表
# docker-compose.yaml → SINGLE_IMAGES
# docker-compose-cluster.yaml → CLUSTER_IMAGES
# docker-compose-monitor.yaml → MONITOR_IMAGES
# mapfile -t SINGLE_IMAGES  < <(docker compose -f "$DOCKER_DIR/docker-compose.yaml" config --images 2>/dev/null | sort -u)
# mapfile -t CLUSTER_IMAGES < <(docker compose -f "$DOCKER_DIR/docker-compose-cluster.yaml" config --images 2>/dev/null | sort -u)
# mapfile -t MONITOR_IMAGES < <(docker compose -f "$DOCKER_DIR/docker-compose-monitor.yaml" config --images 2>/dev/null | sort -u)


# 复制文件到远程节点
MONITOR="root@$MONITOR_HOST"
SERVERS=("root@$SERVER_HOST_1" "root@$SERVER_HOST_2")


# 部署监控
deploy_monitor() {
    h1 "部署监控节点 ${CYAN}$MONITOR_HOST${NC}"
    if $SYNC_FILES; then
        ssh $MONITOR "mkdir -p /root/AiKv-Workflow/" > /dev/null 2>&1
        scp -r $DOCKER_DIR $MONITOR:/root/AiKv-Workflow/ > /dev/null 2>&1
    fi

    info "部署监控服务"
    ssh $MONITOR "docker rm -f \$(docker ps -qa)" > /dev/null 2>&1 || true
    # 监控节点使用 localhost，因为监控组件不跨网络暴露
    ssh $MONITOR "SERVER_HOST=127.0.0.1 docker compose -f /root/AiKv-Workflow/docker/docker-compose-monitor.yaml up -d"
}

# 主部署流程
main() {
    local server=$1
    h1 "部署服务到 ${CYAN}$server${NC}"

    if $SYNC_FILES; then
        h2 "同步文件到远程"
        ssh $server "mkdir -p /root/AiKv-Workflow/" > /dev/null 2>&1
        scp -r $DOCKER_DIR $server:/root/AiKv-Workflow/ > /dev/null 2>&1
    fi

    if $SYNC_IMAGES; then
        h2 "同步镜像到远程"
        if [ ! -f $DOCKER_DIR/aikv-image.tar ]; then
            docker save $IMAGE_NAME -o $DOCKER_DIR/aikv-image.tar
        fi

        scp $DOCKER_DIR/aikv-image.tar $server:/root/AiKv-Workflow/ > /dev/null 2>&1
        ssh $server "docker load -i /root/AiKv-Workflow/aikv-image.tar" > /dev/null 2>&1
        ssh $server "rm -f /root/AiKv-Workflow/aikv-image.tar" > /dev/null 2>&1
    fi

    ssh $server "docker rm -f \$(docker ps -q -f name=aikv-replica) \$(docker ps -q -f name=aikv-master) \$(docker ps -q -f name=aikv)" > /dev/null 2>&1 || true

    # 根据服务器 IP 设置 SERVER_HOST 环境变量
    local server_ip="${server#root@}"  # 提取 IP 部分 (去掉 root@ 前缀)
    local server_host_val="$server_ip"
    # 如果是 SERVER_HOST_2，使用对应的 IP
    [[ "$server_ip" == "$SERVER_HOST_2" ]] && server_host_val="$SERVER_HOST_2"

    info "部署服务 (SERVER_HOST=$server_host_val)"
    ssh $server "SERVER_HOST=$server_host_val docker compose -f /root/AiKv-Workflow/docker/$SERVER_COMPOSE up -d"

    if $CLUSTER_MODE; then
        info "初始化集群 (SERVER_HOST=$server_host_val)"
        # 初始化集群时，需要传入正确的 master/replica 地址
        ssh $server "SERVER_HOST=$server_host_val CLUSTER_REDIS_CONNECT_HOST=$server_host_val ./AiKv-Workflow/docker/init.sh \
            -m ${server_host_val}:6379,${server_host_val}:6382 \
            -r ${server_host_val}:6380,${server_host_val}:6381,${server_host_val}:6383,${server_host_val}:6384"
    fi
}

# === 执行流程 ===
if $BUILD_IMAGE; then
    h1 "构建 ${CYAN}Docker 镜像${NC}"
    cd "$PROJECT_DIR"
    ./scripts/build_docker.sh --dev --cluster
    cd - > /dev/null
fi

if $DEPLOY_MONITOR; then
    h1 "部署 ${CYAN}MONITOR${NC}"
    deploy_monitor
fi

h1 "部署 ${CYAN}AiKv${NC}"
for server in "${SERVERS[@]}"; do
    main $server
done

rm -f $DOCKER_DIR/aikv-image.tar
success "部署完成"
