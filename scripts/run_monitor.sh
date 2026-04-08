#!/bin/bash

# 运行 AiKv 监控栈 (Prometheus + Grafana [+ 可选集群 exporter])
#
# 用法：
#   ./run_monitor.sh                  # 仅监控主栈 docker-compose-monitor.yaml
#   ./run_monitor.sh -c|--cluster     # 同时拉起 docker-compose-cluster-monitor.yaml
#   ./run_monitor.sh -p|--promtail    # 在 SERVER_HOST 远端部署 docker-compose-promtail.yaml（默认不部署）
#   ./run_monitor.sh --stop           # 停止（与启动时使用的 compose 列表一致）
#   ./run_monitor.sh -c -p --stop     # 若之前用 -c/-p 启动，停止时同样带上

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"
CONFIG_SCRIPT="$SCRIPT_DIR/config.sh"

COMPOSE_MAIN="$DOCKER_DIR/docker-compose-monitor.yaml"
COMPOSE_CLUSTER_MON="$DOCKER_DIR/docker-compose-cluster-monitor.yaml"
COMPOSE_PROMTAIL="docker-compose-promtail.yaml"
PROJECT_NAME="aikv-monitor"
PROMTAIL_PROJECT_NAME="aikv-promtail"
ENV_FILE="$DOCKER_DIR/.env"
REMOTE_DEST="/root/Aikv-Workflow"

WITH_CLUSTER_MONITOR=0
WITH_REMOTE_PROMTAIL=0
ACTION="start"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c | --cluster)
            WITH_CLUSTER_MONITOR=1
            shift
            ;;
        -p | --promtail)
            WITH_REMOTE_PROMTAIL=1
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --help | -h)
            echo "用法: $0 [-c|--cluster] [-p|--promtail] [--stop]"
            echo ""
            echo "参数:"
            echo "  -c, --cluster  额外部署 docker-compose-cluster-monitor.yaml(各节点 redis_exporter)"
            echo "  -p, --promtail 额外在 SERVER_HOST 上部署 docker-compose-promtail.yaml"
            echo "  --stop         停止本协议栈"
            echo ""
            echo "启动的服务(默认):"
            echo "  - Prometheus / Grafana / Loki / exporters(见 docker-compose-monitor.yaml)"
            echo "带 -c 时再启动:"
            echo "  - 集群监控 exporters(docker-compose-cluster-monitor.yaml)"
            echo "带 -p 时再启动:"
            echo "  - SERVER_HOST 上的 promtail(docker-compose-promtail.yaml)"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

compose_files=(-f "$COMPOSE_MAIN")
if [[ "$WITH_CLUSTER_MONITOR" -eq 1 ]]; then
    compose_files+=(-f "$COMPOSE_CLUSTER_MON")
fi

run_compose() {
    docker compose -p "$PROJECT_NAME" "${compose_files[@]}" --project-directory "$DOCKER_DIR" "$@"
}

run_remote_promtail() {
    local cmd="$1"
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "缺少 $ENV_FILE，无法解析 SERVER_HOST 以部署 promtail" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    : "${SERVER_HOST:?请在 docker/.env 中设置 SERVER_HOST}"
    local server_ssh
    if [[ "$SERVER_HOST" == *@* ]]; then
        server_ssh="$SERVER_HOST"
    else
        server_ssh="root@${SERVER_HOST}"
    fi
    ssh "$server_ssh" "cd '$REMOTE_DEST/docker' && docker compose -p '$PROMTAIL_PROJECT_NAME' -f '$COMPOSE_PROMTAIL' --project-directory '$REMOTE_DEST/docker' $cmd"
}

if [[ "$ACTION" == "stop" ]]; then
    echo "停止监控栈..."
    run_compose down -v --remove-orphans
    if [[ "$WITH_REMOTE_PROMTAIL" -eq 1 ]]; then
        echo "停止远端 promtail..."
        run_remote_promtail "down -v --remove-orphans"
    fi
    echo "已停止"
    exit 0
fi

if [[ ! -x "$CONFIG_SCRIPT" ]]; then
    echo "缺少可执行脚本: $CONFIG_SCRIPT" >&2
    echo "请先执行: chmod +x $CONFIG_SCRIPT" >&2
    exit 1
fi
echo "生成 Prometheus 运行时配置..."
"$CONFIG_SCRIPT"

echo "清理旧环境..."
run_compose down -v --remove-orphans 2>/dev/null || true

if [[ "$WITH_CLUSTER_MONITOR" -eq 1 ]]; then
    echo "启动监控栈(含 cluster-monitor exporters)..."
else
    echo "启动监控栈(单机 monitor)..."
fi
run_compose up -d
if [[ "$WITH_REMOTE_PROMTAIL" -eq 1 ]]; then
    echo "启动 SERVER_HOST 上的 promtail..."
    run_remote_promtail "up -d"
fi
 
echo ""
echo "=== 监控栈启动成功 ==="
echo ""
echo "服务地址:"
echo "  - aikv-exporter http://localhost:9121"
echo "  - Prometheus    http://localhost:9090"
echo "  - Grafana       http://localhost:3000(admin/admin)"
