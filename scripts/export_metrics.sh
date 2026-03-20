#!/bin/bash

# 导出 AiKv 监控指标
#
# 用法：
#   ./export_metrics.sh --metric=<metric_name> --duration=<duration> [--format=json|csv]
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
#                  AiDb:
#                    - aidb_memtable_bytes             MemTable 大小
#                    - aidb_wal_bytes                  WAL 大小
#                    - aidb_block_cache_bytes          Block Cache 使用量
#                    - aidb_block_cache_capacity_bytes Block Cache 容量
#                    - aidb_all                        所有 AiDb 指标
#                  其他:
#                    - all (所有可用指标)
#   --duration    时间范围，如：5m, 1h, 30m, 24h
#   --format      输出格式：json (默认) 或 csv
#   --list        列出所有可用指标
#
# 示例：
#   ./export_metrics.sh --metric=redis_cpu_user_seconds_total --duration=5m
#   ./export_metrics.sh --metric=all_cpu --duration=1h --format=csv
#   ./export_metrics.sh --list

set -e

PROMETHEUS_URL="http://localhost:9090"

# 解析参数
METRIC=""
DURATION="5m"
FORMAT="json"

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
            echo "AiDb:"
            echo "  aidb_memtable_bytes             - MemTable 大小"
            echo "  aidb_wal_bytes                 - WAL 大小"
            echo "  aidb_block_cache_bytes         - Block Cache 使用量"
            echo "  aidb_block_cache_capacity_bytes - Block Cache 容量"
            echo "  aidb_all                        - 所有 AiDb 指标"
            echo ""
            echo "其他:"
            echo "  all                             - 所有可用指标"
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 --metric=<metric> --duration=<duration> [--format=json|csv] [--list]"
            echo ""
            echo "参数:"
            echo "  --metric      指标名 (必填，可用 --list 查看所有指标)"
            echo "  --duration    时间范围 (默认: 5m)"
            echo "  --format      输出格式: json 或 csv (默认: json)"
            echo "  --list        列出所有可用指标"
            echo ""
            echo "示例:"
            echo "  $0 --metric=redis_cpu_user_seconds_total --duration=5m"
            echo "  $0 --metric=all_cpu --duration=1h --format=csv"
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

# 获取时间戳
NOW=$(date +%s)
SECONDS=$(duration_to_seconds "$DURATION")
START=$((NOW - SECONDS))

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
    aidb_memtable_bytes|aidb_wal_bytes|aidb_block_cache_bytes|aidb_block_cache_capacity_bytes)
        QUERY="$METRIC"
        ;;
    aidb_all)
        QUERY="{__name__=~\"aidb_.*\"}"
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
echo "时间范围: 最近 $DURATION"
echo "时间点: $(date -d @$START '+%Y-%m-%d %H:%M:%S') - $(date -d @$NOW '+%Y-%m-%d %H:%M:%S')"
echo ""

if [[ "$FORMAT" == "csv" ]]; then
    curl -s "$PROMETHEUS_URL/api/v1/query_range" \
        -d "query=$QUERY" \
        -d "start=$START" \
        -d "end=$NOW" \
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
        -d "end=$NOW" \
        -d "step=15s"
fi
