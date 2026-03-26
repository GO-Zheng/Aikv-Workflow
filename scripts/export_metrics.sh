#!/bin/bash

# 导出 AiKv 监控指标
#
# 用法：
#   ./export_metrics.sh --metric=<metric_name> [--duration=<duration>] [--format=json|csv]
#   ./export_metrics.sh --metric=<metric_name> --start=<start_time> --end=<end_time> [--format=json|csv]
#   ./export_metrics.sh --list
#
# 参数：
#   --metric      指标名，支持：
#                  CPU:
#                    - redis_cpu_sys_seconds_total    系统 CPU
#                    - redis_cpu_user_seconds_total   用户 CPU
#                    - all_cpu                        所有 CPU 指标
#                  Memory:
#                    - redis_memory_used_bytes        已分配内存
#                    - redis_memory_used_peak_bytes   峰值内存
#                    - process_resident_memory_bytes  RSS 内存
#                    - redis_mem_fragmentation_ratio  内存碎片率
#                  连接:
#                    - redis_connected_clients        当前连接数
#                    - redis_commands_processed_total 累计命令数
#                  AiDb:
#                    - aidb_memtable_bytes             MemTable 大小
#                    - aidb_wal_bytes                  WAL 大小
#                    - aidb_block_cache_bytes          Block Cache 使用量
#                    - aidb_block_cache_capacity_bytes Block Cache 容量
#                    - aidb_all                        所有 AiDb 指标
#                  QPS/OPS:
#                    - qps                             读命令 QPS
#                    - ops                             所有命令 OPS
#                    - redis_commands_total            按命令类型的统计 (对应"命令类型分布"面板)
#                    - command_ratio                   各命令占比 0-1 (对应"命令类型占比"饼图)
#                  Keyspace:
#                    - keyspace_hits                   Keyspace 命中次数
#                    - keyspace_misses                 Keyspace 未命中次数
#                    - keyspace_ratio                  Keyspace 命中率
#                  Latency:
#                    - latency_p50                    总延迟 P50
#                    - latency_p95                    总延迟 P95
#                    - latency_p99                    总延迟 P99
#                    - latency_by_cmd                 各命令类型延迟
#                  网络:
#                    - redis_net_input_bytes_total  累计接收字节
#                    - redis_net_output_bytes_total 累计发送字节
#                    - net_input_rate              网络输入速率 (bytes/s)
#                    - net_output_rate             网络输出速率 (bytes/s)
#                    - all_net                     所有网络 I/O 指标
#                  其他:
#                    - all (所有可用指标)
#   --duration    时间范围，如：5m, 1h, 30m, 24h (默认: 5m)
#   --start       起始时间 (与 --end 配合使用，优先级高于 --duration)
#                  格式: HH:MM (今天，如 11:30)
#                       YYYY-MM-DD HH:MM (指定日期，如 2026-03-26 11:30)
#                       YYYY-MM-DDTHH:MM (ISO 格式，如 2026-03-26T11:30)
#   --end         结束时间 (与 --start 配合使用)
#                  格式同上 (如 12:00)
#   --format      输出格式：json (默认) 或 csv
#   --list        列出所有可用指标
#
# 示例：
#   ./export_metrics.sh --metric=redis_cpu_user_seconds_total --duration=5m
#   ./export_metrics.sh --metric=all_cpu --duration=1h --format=csv
#   ./export_metrics.sh --metric=ops --start=11:30 --end=12:00
#   ./export_metrics.sh --metric=all --start="2026-03-26 11:30" --end="2026-03-26 12:00"
#   ./export_metrics.sh --list

set -e

PROMETHEUS_URL="http://localhost:9090"

# 解析参数
METRIC=""
DURATION="5m"
FORMAT="json"
START_TIME=""
END_TIME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --metric=*)
            METRIC="${1#*=}"
            shift
            ;;
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
        --format=*)
            FORMAT="${1#*=}"
            shift
            ;;
        --list)
            echo "可用指标："
            echo ""
            echo "CPU:"
            echo "  redis_cpu_sys_seconds_total     - 系统 CPU 时间"
            echo "  redis_cpu_user_seconds_total    - 用户 CPU 时间"
            echo "  all_cpu                         - 所有 CPU 指标"
            echo ""
            echo "Memory:"
            echo "  redis_memory_used_bytes          - 已分配内存"
            echo "  redis_memory_used_peak_bytes    - 峰值内存"
            echo "  process_resident_memory_bytes   - RSS 内存"
            echo "  redis_mem_fragmentation_ratio   - 内存碎片率"
            echo ""
            echo "连接:"
            echo "  redis_connected_clients         - 当前连接数"
            echo "  redis_commands_processed_total  - 累计命令数"
            echo ""
            echo "AiDb:"
            echo "  aidb_memtable_bytes             - MemTable 大小"
            echo "  aidb_wal_bytes                 - WAL 大小"
            echo "  aidb_block_cache_bytes         - Block Cache 使用量"
            echo "  aidb_block_cache_capacity_bytes - Block Cache 容量"
            echo "  aidb_all                        - 所有 AiDb 指标"
            echo ""
            echo "QPS/OPS:"
            echo "  qps                             - 读命令 QPS (get|mget|hget|sget|lget|smembers|scard|sismember)"
            echo "  ops                             - 所有命令 OPS"
            echo "  redis_commands_total            - 按命令类型的统计 (对应\"命令类型分布\"面板)"
            echo "  command_ratio                   - 各命令占比 0-1 (对应\"命令类型占比\"饼图)"
            echo "  keyspace_hits                   - Keyspace 命中次数 (对应\"Keyspace 命中率\"面板)"
            echo "  keyspace_misses                 - Keyspace 未命中次数 (对应\"Keyspace 命中率\"面板)"
            echo "  keyspace_ratio                  - Keyspace 命中率 (0-1)"
            echo ""
            echo "Latency:"
            echo "  latency_p50                    - 总延迟 P50 (秒)"
            echo "  latency_p95                    - 总延迟 P95 (秒)"
            echo "  latency_p99                    - 总延迟 P99 (秒)"
            echo "  latency_by_cmd                - 各命令类型延迟分布"
            echo ""
            echo "Network I/O:"
            echo "  redis_net_input_bytes_total  - 累计接收字节"
            echo "  redis_net_output_bytes_total - 累计发送字节"
            echo "  net_input_rate               - 网络输入速率 (bytes/s)"
            echo "  net_output_rate              - 网络输出速率 (bytes/s)"
            echo "  all_net                      - 所有网络 I/O 指标"
            echo "其他:"
            echo "  all                             - 所有可用指标"
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 --metric=<metric> [--duration=<duration>] [--start=<start>] [--end=<end>] [--format=json|csv] [--list]"
            echo ""
            echo "参数:"
            echo "  --metric      指标名 (必填，可用 --list 查看所有指标)"
            echo "  --duration    时间范围，如: 5m, 1h, 30m, 24h (默认: 5m)"
            echo "  --start       起始时间 (与 --end 配合使用，优先级高于 --duration)"
            echo "                格式: HH:MM, YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM"
            echo "  --end         结束时间 (与 --start 配合使用)"
            echo "  --format      输出格式: json 或 csv (默认: json)"
            echo "  --list        列出所有可用指标"
            echo ""
            echo "示例:"
            echo "  $0 --metric=redis_cpu_user_seconds_total --duration=5m"
            echo "  $0 --metric=ops --start=11:30 --end=12:00"
            echo "  $0 --metric=all --start=\"2026-03-26 11:30\" --end=\"2026-03-26 12:00\""
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$METRIC" ]]; then
    echo "错误: 必须指定 --metric 参数"
    echo "使用 --list 查看所有可用指标"
    exit 1
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

# 解析时间字符串为 Unix 时间戳
parse_time_to_timestamp() {
    local time_str="$1"
    local ts

    # 尝试解析 HH:MM 格式 (今天)
    if [[ "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        local hour="${BASH_REMATCH[1]}"
        local min="${BASH_REMATCH[2]}"
        ts=$(date -d "$(date +%Y-%m-%d) $hour:$min:00" +%s 2>/dev/null) || ts=""
    # 尝试解析 YYYY-MM-DD HH:MM 格式
    elif [[ "$time_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{1,2}:[0-9]{2}$ ]]; then
        ts=$(date -d "$time_str:00" +%s 2>/dev/null) || ts=""
    # 尝试解析 YYYY-MM-DDTHH:MM 格式 (ISO 格式)
    elif [[ "$time_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{1,2}:[0-9]{2}$ ]]; then
        ts=$(date -d "$time_str:00" +%s 2>/dev/null) || ts=""
    else
        ts=""
    fi

    echo "$ts"
}

# 计算时间范围
NOW=$(date +%s)

if [[ -n "$START_TIME" && -n "$END_TIME" ]]; then
    # 使用绝对时间范围
    START=$(parse_time_to_timestamp "$START_TIME")
    END=$(parse_time_to_timestamp "$END_TIME")

    if [[ -z "$START" || -z "$END" ]]; then
        echo "错误: 无法解析时间格式: $START_TIME 或 $END_TIME"
        echo "支持的格式: HH:MM, YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM"
        exit 1
    fi

    if [[ "$START" -ge "$END" ]]; then
        echo "错误: 起始时间必须早于结束时间"
        exit 1
    fi

    TIME_DESC="$START_TIME - $END_TIME"
else
    # 使用相对时间
    SECONDS=$(duration_to_seconds "$DURATION")
    START=$((NOW - SECONDS))
    END=$NOW
    TIME_DESC="最近 $DURATION ($(date -d @$START '+%Y-%m-%d %H:%M:%S') - $(date -d @$END '+%Y-%m-%d %H:%M:%S'))"
fi

# PromQL 查询
case "$METRIC" in
    redis_cpu_sys_seconds_total)
        QUERY="rate(redis_cpu_sys_seconds_total[1m])"
        ;;
    redis_cpu_user_seconds_total)
        QUERY="rate(redis_cpu_user_seconds_total[1m])"
        ;;
    all_cpu)
        QUERY="{__name__=~\"redis_cpu_.*\"}"
        ;;
    redis_memory_used_bytes|redis_memory_used_peak_bytes|process_resident_memory_bytes|redis_mem_fragmentation_ratio)
        QUERY="$METRIC"
        ;;
    redis_connected_clients|redis_commands_processed_total)
        QUERY="$METRIC"
        ;;
    aidb_memtable_bytes|aidb_wal_bytes|aidb_block_cache_bytes|aidb_block_cache_capacity_bytes)
        QUERY="$METRIC"
        ;;
    aidb_all)
        QUERY="{__name__=~\"aidb_.*\"}"
        ;;
    qps)
        QUERY="sum(rate(redis_commands_total{cmd=~\"get|mget|hget|sget|lget|smembers|scard|sismember\"}[1m]))"
        ;;
    ops)
        QUERY="sum(rate(redis_commands_total[1m]))"
        ;;
    command_ratio)
        QUERY="sum(rate(redis_commands_total[1m])) by (cmd) / ignoring(cmd) group_left sum(rate(redis_commands_total[1m]))"
        ;;
    keyspace_hits)
        QUERY="rate(redis_keyspace_hits_total[1m])"
        ;;
    keyspace_misses)
        QUERY="rate(redis_keyspace_misses_total[1m])"
        ;;
    keyspace_ratio)
        QUERY="rate(redis_keyspace_hits_total[1m]) / (rate(redis_keyspace_hits_total[1m]) + rate(redis_keyspace_misses_total[1m]))"
        ;;
    latency_p50)
        QUERY="histogram_quantile(0.50, sum(rate(redis_commands_latencies_usec_bucket[1m])) by (le)) / 1e6"
        ;;
    latency_p95)
        QUERY="histogram_quantile(0.95, sum(rate(redis_commands_latencies_usec_bucket[1m])) by (le)) / 1e6"
        ;;
    latency_p99)
        QUERY="histogram_quantile(0.99, sum(rate(redis_commands_latencies_usec_bucket[1m])) by (le)) / 1e6"
        ;;
    latency_by_cmd)
        QUERY="histogram_quantile(0.50, sum(rate(redis_commands_latencies_usec_bucket[1m])) by (le, cmd)) / 1e6"
        ;;
    redis_net_input_bytes_total|redis_net_output_bytes_total)
        QUERY="$METRIC"
        ;;
    net_input_rate)
        QUERY="rate(redis_net_input_bytes_total[1m])"
        ;;
    net_output_rate)
        QUERY="rate(redis_net_output_bytes_total[1m])"
        ;;
    all_net)
        QUERY="{__name__=~\"redis_net_.*\"}"
        ;;
    redis_commands_total|commands_all)
        QUERY="rate(redis_commands_total[1m])"
        ;;
    all)
        QUERY="{__name__=~\"redis_.*|process_.*|aidb_.*\"}"
        ;;
    *)
        QUERY="$METRIC"
        ;;
esac

# 调用 Prometheus API
echo "导出指标: $METRIC"
echo "时间范围: $TIME_DESC"
echo ""

if [[ "$FORMAT" == "csv" ]]; then
    curl -s "$PROMETHEUS_URL/api/v1/query_range" \
        -d "query=$QUERY" \
        -d "start=$START" \
        -d "end=$END" \
        -d "step=15s" | jq -r '
            if .status == "success" then
                .data.result[] |
                (.metric | to_entries | map("\(.key)=\(.value)") | join(",")),
                (.values | map("\(.[0] | todateiso8601),\(.[1])") | join("\n"))
            else
                .error
            end
        '
else
    curl -s "$PROMETHEUS_URL/api/v1/query_range" \
        -d "query=$QUERY" \
        -d "start=$START" \
        -d "end=$END" \
        -d "step=15s"
fi