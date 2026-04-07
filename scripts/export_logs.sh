#!/bin/bash

# 导出 AiKv 日志
#
# 用法: 
#   ./export_logs.sh [--duration=<duration>] [--format=json|csv]
#   ./export_logs.sh --start=<start_time> --end=<end_time> [--level=<level>] [--service=<service>] [--format=json|csv]
#   ./export_logs.sh --list
#
# 参数: 
#   --duration    时间范围, 如: 5m, 1h, 30m, 24h (默认: 5m)
#   --start       起始时间 (与 --end 配合使用, 优先级高于 --duration)
#                  格式: HH:MM (今天, 如 11:30)
#                       YYYY-MM-DD HH:MM (指定日期, 如 2026-03-26 11:30)
#                       YYYY-MM-DDTHH:MM (ISO 格式, 如 2026-03-26T11:30)
#   --end         结束时间 (与 --start 配合使用)
#                  格式同上 (如 12:00)
#   --level       日志级别过滤: error, warn, info, debug (可选, 多个用逗号分隔)
#   --service     服务名过滤, 如: aikv (对应 Promtail 的 job 标签)
#   --host        节点名过滤 (service 标签), 如: aikv-master-1, aikv-replica-1
#   --limit       最大返回条数 (默认: 1000, 上限 5000)
#   --format      输出格式: json (默认) 或 csv
#   --list        列出所有可用标签和值
#
# 示例: 
#   ./export_logs.sh --duration=5m
#   ./export_logs.sh --start=11:30 --end=12:00
#   ./export_logs.sh --start="2026-03-26 11:30" --end="2026-03-26 12:00"
#   ./export_logs.sh --level=error --duration=1h
#   ./export_logs.sh --service=aikv --level=error,warn --duration=30m
#   ./export_logs.sh --list

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_ENV="$(dirname "$SCRIPT_DIR")/docker/.env"
if [[ ! -f "$DOCKER_ENV" ]]; then
  echo "错误: 缺少环境文件 $DOCKER_ENV" >&2
  echo "请先复制 docker/.env.example 为 docker/.env 并设置 MONITOR_HOST" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$DOCKER_ENV"
set +a
: "${MONITOR_HOST:?错误: docker/.env 中缺少 MONITOR_HOST}"
LOKI_URL="http://${MONITOR_HOST}:3100"

# 解析参数
DURATION="5m"
FORMAT="json"
START_TIME=""
END_TIME=""
LEVEL=""
SERVICE=""
HOST=""
LIMIT="1000"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration=*)
            DURATION="${1#*=}"
            shift
            ;;
        --start=*)
            START_TIME="${1#*=}"
            shift
            ;;
        --end=*)
            END_TIME="${1#*=}"
            shift
            ;;
        --level=*)
            LEVEL="${1#*=}"
            shift
            ;;
        --service=*)
            SERVICE="${1#*=}"
            shift
            ;;
        --host=*)
            HOST="${1#*=}"
            shift
            ;;
        --limit=*)
            LIMIT="${1#*=}"
            shift
            ;;
        --format=*)
            FORMAT="${1#*=}"
            shift
            ;;
        --list)
            echo "=== 可用标签 ==="
            echo ""
            echo "获取标签名: "
            curl -s "$LOKI_URL/loki/api/v1/label" | jq -r '.data[]' 2>/dev/null
            echo ""
            echo "获取 job 标签值: "
            curl -s "$LOKI_URL/loki/api/v1/label/job/values" | jq -r '.data[]' 2>/dev/null
            echo ""
            echo "获取 service 标签值: "
            curl -s "$LOKI_URL/loki/api/v1/label/service/values" | jq -r '.data[]' 2>/dev/null
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 [--duration=<duration>] [--start=<start>] [--end=<end>] [--level=<level>] [--service=<service>] [--host=<host>] [--limit=<n>] [--format=json|csv] [--list]"
            echo ""
            echo "参数:"
            echo "  --duration    时间范围, 如: 5m, 1h, 30m, 24h (默认: 5m)"
            echo "  --start       起始时间 (与 --end 配合使用, 优先级高于 --duration)"
            echo "                格式: HH:MM, YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM"
            echo "  --end         结束时间 (与 --start 配合使用)"
            echo "  --level       日志级别过滤: error, warn, info, debug (逗号分隔多个)"
            echo "  --service     服务名过滤 (job 标签)"
            echo "  --host        节点名过滤 (service 标签), 如: aikv-master-1, aikv-replica-1"
            echo "  --limit       最大返回条数 (默认: 1000, 上限 5000)"
            echo "  --format      输出格式: json 或 csv (默认: json)"
            echo "  --list        列出所有可用标签"
            echo ""
            echo "示例:"
            echo "  $0 --duration=5m"
            echo "  $0 --level=error --duration=1h"
            echo "  $0 --service=aikv --level=error,warn --start=11:30 --end=12:00"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 将 duration 转换为秒
duration_to_seconds() {
    local dur=$1
    local num=${dur%[mhd]*}
    local unit=${dur#$num}
    case "$unit" in
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) echo "$num" ;;
    esac
}

# 解析时间字符串为 Unix 纳秒时间戳
parse_time_to_nano() {
    local time_str="$1"
    local ts

    # 尝试解析 HH:MM 格式 (今天)
    if [[ "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        local min="${BASH_REMATCH[2]}"
        ts=$(date -d "$(date +%Y-%m-%d) $hour:$min:00" +%s 2>/dev/null) || ts=""
        if [[ -n "$ts" ]]; then
            echo $((ts * 1000000000))
            return
        fi
    # 尝试解析 YYYY-MM-DD HH:MM 格式
    elif [[ "$time_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{1,2}:[0-9]{2}$ ]]; then
        ts=$(date -d "$time_str:00" +%s 2>/dev/null) || ts=""
        if [[ -n "$ts" ]]; then
            echo $((ts * 1000000000))
            return
        fi
    # 尝试解析 YYYY-MM-DDTHH:MM 格式 (ISO 格式)
    elif [[ "$time_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{1,2}:[0-9]{2}$ ]]; then
        ts=$(date -d "$time_str:00" +%s 2>/dev/null) || ts=""
        if [[ -n "$ts" ]]; then
            echo $((ts * 1000000000))
            return
        fi
    fi

    echo ""
}

# 计算时间范围
NOW_NS=$(date +%s000000000)

if [[ -n "$START_TIME" && -n "$END_TIME" ]]; then
    # 使用绝对时间范围
    START_NS=$(parse_time_to_nano "$START_TIME")
    END_NS=$(parse_time_to_nano "$END_TIME")

    if [[ -z "$START_NS" || -z "$END_NS" ]]; then
        echo "错误: 无法解析时间格式: $START_TIME 或 $END_TIME"
        echo "支持的格式: HH:MM, YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM"
        exit 1
    fi

    if [[ "$START_NS" -ge "$END_NS" ]]; then
        echo "错误: 起始时间必须早于结束时间"
        exit 1
    fi

    TIME_DESC="$START_TIME - $END_TIME"
else
    # 使用相对时间
    SECONDS=$(duration_to_seconds "$DURATION")
    END_NS=$NOW_NS
    START_NS=$((NOW_NS - SECONDS * 1000000000))
    TIME_DESC="最近 $DURATION"
fi

# 构建 LogQL 查询
build_logql() {
    local query=""

    # 服务过滤 (job 标签)
    local job_filter
    if [[ -n "$SERVICE" ]]; then
        job_filter="{job=\"$SERVICE\"}"
    else
        job_filter="{job=~\".+\"}"
    fi

    # 主机过滤 (service 标签, 对应 Promtail 的 service label)
    if [[ -n "$HOST" ]]; then
        if [[ -n "$SERVICE" ]]; then
            query="{job=\"$SERVICE\", service=\"$HOST\"}"
        else
            query="{job=\"aikv\", service=\"$HOST\"}"
        fi
    else
        query="$job_filter"
    fi

    # 级别过滤 (使用 |= 过滤日志内容中的 level 字段)
    if [[ -n "$LEVEL" ]]; then
        IFS=',' read -ra LEVELS <<< "$LEVEL"
        for lvl in "${LEVELS[@]}"; do
            lvl=$(echo "$lvl" | tr '[:lower:]' '[:upper:]')
            query="$query |= \"$lvl\""
        done
    fi

    echo "$query"
}

QUERY=$(build_logql)

echo "导出日志"
echo "时间范围: $TIME_DESC"
echo "查询条件: $QUERY"
echo "限制: $LIMIT 条"
echo ""

# 调用 Loki API
# 使用 range query 获取一段时间内的日志
START_S=$((START_NS / 1000000000))
END_S=$((END_NS / 1000000000))

if [[ "$FORMAT" == "csv" ]]; then
    curl -s "$LOKI_URL/loki/api/v1/query_range" \
        -G \
        --data-urlencode "query=$QUERY" \
        -d "start=$START_NS" \
        -d "end=$END_NS" \
        -d "limit=$LIMIT" \
        -d "direction=backward" | jq -r '
            if .status == "success" then
                .data.result[] |
                .stream as $stream |
                .values[] |
                (($stream | to_entries | map("\(.key)=\(.value)") | join(" | ")) // ""),
                (.[0] | tonumber / 1e9 | todateiso8601),
                .[1]
            else
                .error
            end
        '
else
    curl -s "$LOKI_URL/loki/api/v1/query_range" \
        -G \
        --data-urlencode "query=$QUERY" \
        -d "start=$START_NS" \
        -d "end=$END_NS" \
        -d "limit=$LIMIT" \
        -d "direction=backward"
fi
