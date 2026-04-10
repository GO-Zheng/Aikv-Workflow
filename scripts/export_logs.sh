#!/bin/bash

# 导出 AiKv 日志
#
# 诊断字段说明（便于用 --diag-event / --contains 拉链路）:
#   AiKv 当前默认定宽文本 tracing：diag_event 出现在行内，请优先 --contains=diag_event=...
#   若 AiKv 改回 JSON 且 Promtail 能解析，可用 --diag-event（走 | json | diag_event=...）
#   AiKv tracing diag_event（与源码一致，优先 --contains=diag_event=...）：
#     redis_listen_bound                 Redis 协议监听就绪（含 redis_listen 地址）
#     cluster_init_complete_before_redis_bind  集群初始化完成、尚未绑定 Redis 端口
#     cluster_raft_forward_to_moved      ForwardToLeader 已映射为 MOVED
#     cluster_raft_forward_unparsed      ForwardToLeader 无法解析 leader 地址
#     cluster_raft_no_local_group        写入路由到本机不存在的 Raft group
#     cluster_client_moved               客户端 MOVED 类重定向相关（多为 debug）
#     cluster_command_storage_err        命令返回 ERR…Storage（含客户端、命令名）
#     cluster_command_internal_err       命令返回 Internal
#     cluster_command_io_protocol_err    I/O 或协议类错误
#     cluster_command_err_other          其他命令错误
#   AiDb 文本日志（用 --contains=diag_event=...）:
#     diag_event=db_write_batch_resync_retry
#     diag_event=db_write_batch_no_group_after_sync
#
# 用法: 
#   ./export_logs.sh [--duration=<duration>] [--format=json|csv]
#   ./export_logs.sh --start=<start_time> --end=<end_time> [--level=<level>] [--service=<service>] [--format=json|csv]
#   ./export_logs.sh --list
#   ./export_logs.sh --diag-event=cluster_command_storage_err --duration=15m
#   ./export_logs.sh --contains=diag_event=db_write_batch --duration=15m
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
#   --host        节点名过滤 (service 标签), 如: aikv-master-1, aikv-replica-1a
#   --request-id  请求 ID 过滤 (JSON 字段)
#   --diag-event  诊断事件名 (JSON 字段 diag_event, 与 AiKv tracing 一致)
#   --diag-events 多个诊断事件（逗号分隔，文本模式按 diag_event=... 正则匹配）
#   --diag-mode   diag_event 过滤模式: auto|json|contains (默认: auto)
#   --scenario    迁移排障场景快捷过滤:
#                 migration-setslot|migration-ask|migration-migrate|migration-forward
#   --contains    行级子串过滤 (LogQL |=, 适用于 aidb log:: 文本中的 diag_event=...)
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
REQUEST_ID=""
DIAG_EVENT=""
DIAG_EVENTS=""
DIAG_MODE="auto"
SCENARIO=""
CONTAINS=""
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
        --request-id=*)
            REQUEST_ID="${1#*=}"
            shift
            ;;
        --diag-event=*)
            DIAG_EVENT="${1#*=}"
            shift
            ;;
        --diag-events=*)
            DIAG_EVENTS="${1#*=}"
            shift
            ;;
        --diag-mode=*)
            DIAG_MODE="${1#*=}"
            shift
            ;;
        --scenario=*)
            SCENARIO="${1#*=}"
            shift
            ;;
        --contains=*)
            CONTAINS="${1#*=}"
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
            echo "用法: $0 [--duration=...] [--start=...] [--end=...] [--level=...] [--service=...] [--host=...] [--request-id=...] [--diag-event=...] [--diag-events=...] [--diag-mode=auto|json|contains] [--scenario=...] [--contains=...] [--limit=...] [--format=json|csv] [--list]"
            echo ""
            echo "参数:"
            echo "  --duration    时间范围, 如: 5m, 1h, 30m, 24h (默认: 5m)"
            echo "  --start       起始时间 (与 --end 配合使用, 优先级高于 --duration)"
            echo "                格式: HH:MM, YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM"
            echo "  --end         结束时间 (与 --start 配合使用)"
            echo "  --level       日志级别过滤: error, warn, info, debug (逗号分隔多个)"
            echo "  --service     服务名过滤 (job 标签)"
            echo "  --host        节点名过滤 (service 标签), 如: aikv-master-1, aikv-replica-1a"
            echo "  --request-id  请求 ID 过滤 (JSON 字段)"
            echo "  --diag-event  诊断事件 (JSON 字段 diag_event)"
            echo "  --diag-events 多个诊断事件（逗号分隔）"
            echo "  --diag-mode   diag_event 过滤模式: auto|json|contains (默认 auto)"
            echo "  --scenario    迁移场景快捷过滤: migration-setslot|migration-ask|migration-migrate|migration-forward"
            echo "  --contains    行子串 (LogQL |=)"
            echo "  --limit       最大返回条数 (默认: 1000, 上限 5000)"
            echo "  --format      输出格式: json 或 csv (默认: json)"
            echo "  --list        列出所有可用标签"
            echo ""
            echo "示例:"
            echo "  $0 --duration=5m"
            echo "  $0 --level=error --duration=1h"
            echo "  $0 --service=aikv --level=error,warn --start=11:30 --end=12:00"
            echo "  $0 --diag-event=cluster_command_storage_err --duration=30m"
            echo "  $0 --contains=diag_event=db_write_batch_no_group --duration=30m"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 场景快捷过滤（仅在未显式传 --diag-event/--diag-events 时生效）
if [[ -n "$SCENARIO" && -z "$DIAG_EVENT" && -z "$DIAG_EVENTS" ]]; then
    case "$SCENARIO" in
        migration-setslot)
            DIAG_EVENTS="cluster_setslot_attempt,cluster_setslot_forward_to_leader,cluster_setslot_meta_apply_success,cluster_setslot_meta_apply_failed,cluster_meta_post_sync_start,cluster_meta_post_sync_success,cluster_meta_post_sync_failed"
            ;;
        migration-ask)
            DIAG_EVENTS="cluster_client_ask,cluster_client_asking_marked,cluster_route_check_ask_redirect,cluster_route_check_allow_importing,cluster_route_check_moved_redirect"
            ;;
        migration-migrate)
            DIAG_EVENTS="cluster_migrate_attempt,cluster_migrate_connect_failed,cluster_migrate_auth_failed,cluster_migrate_restore_failed,cluster_migrate_delete_source_failed,cluster_migrate_nokey,cluster_migrate_success"
            ;;
        migration-forward)
            DIAG_EVENTS="cluster_setslot_forward_rpc_attempt,cluster_setslot_forward_rpc_failed,cluster_setslot_forward_rpc_success,cluster_raft_forward_to_moved,cluster_raft_forward_unparsed"
            ;;
        *)
            echo "错误: 不支持的 --scenario=$SCENARIO" >&2
            exit 1
            ;;
    esac
fi

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

# 构建 LogQL 查询（标签选择 + JSON 字段过滤）
build_logql() {
    local selector='job="aikv"'
    local query

    # 服务过滤 (job 标签)
    if [[ -n "$SERVICE" ]]; then
        selector="job=\"$SERVICE\""
    fi

    # 容器名过滤 (service 标签)
    if [[ -n "$HOST" ]]; then
        selector="$selector, service=\"$HOST\""
    fi

    # 级别过滤（Promtail 已提取为 label，转为小写做正则）
    if [[ -n "$LEVEL" ]]; then
        local level_regex
        level_regex="$(echo "$LEVEL" | sed 's/,/|/g')"
        selector="$selector, level=~\"(?i)$level_regex\""
    fi

    query="{$selector}"

    # request_id 过滤（JSON 字段）
    if [[ -n "$REQUEST_ID" ]]; then
        query="$query | json | request_id=\"$REQUEST_ID\""
    fi

    # diag_event（支持 json/contains/auto）
    if [[ -n "$DIAG_EVENT" ]]; then
        case "$DIAG_MODE" in
            json)
                query="$query | json | diag_event=\"$DIAG_EVENT\""
                ;;
            contains|auto)
                query="$query |= \"diag_event=$DIAG_EVENT\""
                ;;
            *)
                echo "错误: 不支持的 --diag-mode=$DIAG_MODE" >&2
                exit 1
                ;;
        esac
    fi

    # diag_events（多个事件，文本正则模式）
    if [[ -n "$DIAG_EVENTS" ]]; then
        local ev_regex
        ev_regex="$(echo "$DIAG_EVENTS" | sed 's/,/|/g')"
        query="$query |~ \"diag_event=($ev_regex)\""
    fi

    # 行级子串（如 aidb log:: 输出的 diag_event=...）；勿含双引号
    if [[ -n "$CONTAINS" ]]; then
        local esc="${CONTAINS//\"/\\\"}"
        query="$query |= \"$esc\""
    fi

    echo "$query"
}

QUERY=$(build_logql)

echo "导出日志"
echo "时间范围: $TIME_DESC"
echo "查询条件: $QUERY"
[[ -n "$DIAG_EVENT" ]] && echo "diag_event: $DIAG_EVENT"
[[ -n "$DIAG_EVENTS" ]] && echo "diag_events: $DIAG_EVENTS"
[[ -n "$SCENARIO" ]] && echo "scenario: $SCENARIO"
[[ -n "$CONTAINS" ]] && echo "行子串(contains): $CONTAINS"
echo "限制: $LIMIT 条"
echo ""

# 调用 Loki API
# 使用 range query 获取一段时间内的日志
START_S=$((START_NS / 1000000000))
END_S=$((END_NS / 1000000000))

RESP="$(curl -s "$LOKI_URL/loki/api/v1/query_range" \
    -G \
    --data-urlencode "query=$QUERY" \
    -d "start=$START_NS" \
    -d "end=$END_NS" \
    -d "limit=$LIMIT" \
    -d "direction=backward")"

STATUS="$(echo "$RESP" | jq -r '.status // "error"' 2>/dev/null || echo "error")"
if [[ "$STATUS" != "success" ]]; then
    echo "Loki 查询失败:" >&2
    echo "$RESP" | jq -r '.error // .message // "unknown error"' 2>/dev/null >&2 || echo "$RESP" >&2
    exit 1
fi

RESULT_COUNT="$(echo "$RESP" | jq '.data.result | length')"
if [[ "$RESULT_COUNT" -eq 0 ]]; then
    echo "未查询到日志（可能时间窗口过短或过滤条件过严）"
    exit 0
fi

if [[ "$FORMAT" == "csv" ]]; then
    echo "$RESP" | jq -r '
        .data.result[] |
        .stream as $stream |
        .values[] |
        (($stream | to_entries | map("\(.key)=\(.value)") | join(" | ")) // ""),
        (.[0] | tonumber / 1e9 | todateiso8601),
        .[1]
    '
else
    echo "$RESP"
fi
