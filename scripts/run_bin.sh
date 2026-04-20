#!/bin/bash

# 启动 AiKv 服务并执行冒烟测试
#
# 用法：
#   ./run_aikv.sh           # 启动服务(默认 AiDb 模式)
#   ./run_aikv.sh --memory  # 启动服务(memory 模式)
#   ./run_aikv.sh --help    # 查看帮助

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_DIR="$PROJECT_DIR/target"
CONFIG_SOURCE="$PROJECT_DIR/docker/config/aikv.toml"
CONFIG_TARGET="$TARGET_DIR/aikv.toml"
BINARY="$TARGET_DIR/aikv"
PID_FILE="$TARGET_DIR/aikv.pid"
LOG_DIR="$PROJECT_DIR/logs"

# 解析参数
USE_MEMORY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --memory)
            USE_MEMORY=true
            shift
            ;;
        --help|-h)
            echo "用法: $0 [--memory]"
            echo ""
            echo "参数:"
            echo "  --memory  使用 memory 模式(默认: AiDb 持久化模式)"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 检查二进制文件是否存在
if [[ ! -f "$BINARY" ]]; then
    echo "错误: $BINARY 不存在"
    echo "请先运行 build_bin.sh 构建项目"
    exit 1
fi

# 复制配置文件
echo "复制配置文件..."
cp "$CONFIG_SOURCE" "$CONFIG_TARGET"

# 如果使用 memory 模式，修改配置
if [[ "$USE_MEMORY" == true ]]; then
    echo "配置 memory 模式..."
    sed -i 's/engine = "aidb"/engine = "memory"/' "$CONFIG_TARGET"
fi

# 停止已存在的服务
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "停止旧服务 (PID: $OLD_PID)..."
        kill "$OLD_PID"
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# 清理可能存在的旧端口进程
if lsof -i :6379 >/dev/null 2>&1; then
    echo "清理占用 6379 端口的进程..."
    pkill -f "aikv" || true
    sleep 1
fi

# 创建日志和数据目录
mkdir -p "$LOG_DIR"
mkdir -p "$PROJECT_DIR/data/aikv"

# 日志文件以当前时间命名
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/aikv_${TIMESTAMP}.log"

# 启动服务
echo "启动 AiKv 服务..."
cd "$PROJECT_DIR"
nohup "$BINARY" --config "$CONFIG_TARGET" > "$LOG_FILE" 2>&1 &
BINARY_PID=$!
echo $BINARY_PID > "$PID_FILE"
echo "服务已启动 (PID: $BINARY_PID)"
echo "日志文件: $LOG_FILE"

# 等待服务就绪
echo "等待服务就绪..."
for i in {1..30}; do
    if redis-cli -p 6379 PING >/dev/null 2>&1; then
        echo "服务已就绪"
        break
    fi
    if ! kill -0 "$BINARY_PID" 2>/dev/null; then
        echo "错误: 服务启动失败"
        exit 1
    fi
    sleep 0.5
done

# 执行功能测试脚本
"$PROJECT_DIR/tests/test_functional.sh"

