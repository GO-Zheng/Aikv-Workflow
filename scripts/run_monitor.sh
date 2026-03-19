#!/bin/bash

# 运行 AiKv 监控栈 (Prometheus + Grafana)
#
# 用法：
#   ./run_monitor.sh              # 启动监控栈
#   ./run_monitor.sh --stop       # 停止监控栈

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_DIR/docker"

COMPOSE_FILE="$DOCKER_DIR/docker-compose-monitor.yaml"

# 解析参数
ACTION="start"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop)
            ACTION="stop"
            shift
            ;;
        --help|-h)
            echo "用法: $0 [--stop]"
            echo ""
            echo "参数:"
            echo "  --stop    停止监控栈"
            echo ""
            echo "启动的服务:"
            echo "  - Prometheus (http://localhost:9090)"
            echo "  - Grafana   (http://localhost:3000, admin/admin)"
            echo "  - node-exporter     (http://localhost:9100)"
            echo "  - aikv-exporter     (http://localhost:9121)"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ "$ACTION" == "stop" ]]; then
    echo "停止监控栈..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
    echo "已停止"
    exit 0
fi

# 确保数据目录存在
mkdir -p "$PROJECT_DIR/data/prometheus"
mkdir -p "$PROJECT_DIR/data/grafana"

# 清理旧容器和网络（确保环境干净）
echo "清理旧环境..."
docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true

# 启动监控栈
echo "启动监控栈..."
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo "=== 监控栈启动成功 ==="
echo ""
echo "服务地址:"
echo "  - Prometheus  http://localhost:9090"
echo "  - Grafana     http://localhost:3000  (admin/admin)"
echo "  - node-exporter   http://localhost:9100"
echo "  - aikv-exporter   http://localhost:9121"
