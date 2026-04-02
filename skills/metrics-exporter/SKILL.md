---
name: metrics-exporter
description: AiKv 监控指标导出工具
user-invocable: true
---

# Metrics Exporter Skill

导出 AiKv 监控指标数据，供 AI 分析使用。

## 执行要求

**必须使用 Skill 工具调用本 Skill，执行其中的脚本命令。禁止绕过 Skill 直接执行 Bash 命令。**

## 脚本路径

脚本位于 `scripts/export_metrics.sh`，会自动定位项目目录。

## 功能

- 导出指定时间范围内的 Prometheus 指标
- 支持 JSON/CSV 格式输出
- 支持自定义时间范围

## 命令

### 列出可用指标
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --list
```

### 导出单个指标（相对时间）
```bash
# 导出最近 5 分钟的 User CPU
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=redis_cpu_user_seconds_total --duration=5m

# 导出最近 1 小时
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=redis_cpu_sys_seconds_total --duration=1h
```

### 导出单个指标（绝对时间）
```bash
# 导出今天 11:30 - 12:00 的 OPS
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=ops --start=11:30 --end=12:00

# 导出指定日期时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all --start="2026-03-26 11:30" --end="2026-03-26 12:00"

# 也支持 ISO 格式
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=ops --start="2026-03-26T11:30" --end="2026-03-26T12:00"
```

### 导出所有 CPU 指标
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all_cpu --duration=30m
```

### 导出所有 AiKv 指标
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all --duration=5m
```

### 输出 CSV 格式
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all_cpu --duration=1h --format=csv
```

## 常用指标

| 指标名 | 说明 | 对应面板 |
|--------|------|----------|
| redis_cpu_sys_seconds_total | 系统 CPU 时间 | CPU 使用率 |
| redis_cpu_user_seconds_total | 用户 CPU 时间 | CPU 使用率 |
| redis_memory_used_bytes | 已分配内存 | 内存使用量 |
| redis_memory_used_peak_bytes | 峰值内存 | 内存使用量 |
| process_resident_memory_bytes | RSS 内存 | 内存使用量 |
| redis_mem_fragmentation_ratio | 内存碎片率 | 内存碎片率 |
| redis_connected_clients | 当前连接数 | 当前连接数 |
| redis_commands_processed_total | 累计命令数 | 累计命令数 |
| aidb_memtable_bytes | MemTable 大小 | AiDb MemTable |
| aidb_wal_bytes | WAL 大小 | AiDb WAL |
| aidb_block_cache_bytes | Block Cache 使用量 | AiDb Block Cache |
| aidb_block_cache_capacity_bytes | Block Cache 容量 | AiDb Block Cache |
| qps | 读命令 QPS | QPS/OPS |
| ops | 所有命令 OPS | QPS/OPS |
| redis_commands_total | 按命令类型的统计 | 命令类型分布 |
| command_ratio | 各命令占比 (0-1) | 命令类型占比 |
| keyspace_hits | Keyspace 命中次数 | Keyspace 命中率 |
| keyspace_misses | Keyspace 未命中次数 | Keyspace 命中率 |
| keyspace_ratio | Keyspace 命中率 (0-1) | Keyspace 命中率 |
| latency_p50 | 总延迟 P50 (秒) | 命令延迟 P50/P95/P99 |
| latency_p95 | 总延迟 P95 (秒) | 命令延迟 P50/P95/P99 |
| latency_p99 | 总延迟 P99 (秒) | 命令延迟 P50/P95/P99 |
| latency_by_cmd | 各命令类型延迟分布 | 命令类型延迟分布 |
| redis_net_input_bytes_total | 累计接收字节 | 网络 I/O 速率 |
| redis_net_output_bytes_total | 累计发送字节 | 网络 I/O 速率 |
| net_input_rate | 网络输入速率 (bytes/s) | 网络 I/O 速率 |
| net_output_rate | 网络输出速率 (bytes/s) | 网络 I/O 速率 |
| all_net | 所有网络 I/O 指标 | 网络 I/O 速率 |
| disk_read_rate | 磁盘读取速率 (bytes/s) | 磁盘 I/O 速率 |
| disk_write_rate | 磁盘写入速率 (bytes/s) | 磁盘 I/O 速率 |
| disk_read_iops | 磁盘读取 IOPS | 磁盘 IOPS |
| disk_write_iops | 磁盘写入 IOPS | 磁盘 IOPS |
| all_disk | 所有磁盘 I/O 指标 | 磁盘 I/O |
| all_cpu | 所有 CPU 相关指标 | CPU 相关面板 |
| aidb_all | 所有 AiDb 指标 | AiDb 相关面板 |
| all | 所有可用指标 | 全部面板 |

## 使用场景

- 用户想分析最近一段时间的 CPU 变化趋势
- 需要导出数据给 AI 进行性能分析
- 检查某个指标的历史变化

## 示例：分析 CPU 使用率

1. 导出数据：
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all_cpu --duration=5m
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析 QPS/OPS

1. 导出数据：
```bash
# 导出 QPS 和 OPS
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=qps --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=ops --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=ops --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析命令类型分布

1. 导出各命令类型的 QPS：
```bash
# 导出所有命令类型的趋势
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=redis_commands_total --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=redis_commands_total --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析命令占比（饼图）

1. 导出各命令占比（已计算好百分比）：
```bash
# 导出当前各命令占比
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=command_ratio --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=command_ratio --start=11:30 --end=12:00
```

2. 直接返回每个命令的占比 (0-1) 发送给 AI 分析

## 示例：分析 Keyspace 命中率

1. 导出数据：
```bash
# 导出命中率趋势
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=keyspace_ratio --duration=5m

# 导出命中和未命中次数
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=keyspace_hits --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=keyspace_misses --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=keyspace_ratio --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析命令延迟

1. 导出数据：
```bash
# 导出 P50/P95/P99 延迟
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=latency_p50 --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=latency_p95 --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=latency_p99 --duration=5m

# 导出各命令类型延迟
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=latency_by_cmd --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=latency_p99 --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析网络 I/O

1. 导出数据：
```bash
# 导出网络输入/输出速率
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=net_input_rate --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=net_output_rate --duration=5m

# 导出所有网络 I/O 指标
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all_net --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=net_input_rate --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析磁盘 I/O

1. 导出数据：
```bash
# 导出磁盘读取/写入速率
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=disk_read_rate --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=disk_write_rate --duration=5m

# 导出磁盘 IOPS
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=disk_read_iops --duration=5m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=disk_write_iops --duration=5m

# 导出所有磁盘 I/O 指标
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=all_disk --duration=5m

# 导出指定时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_metrics.sh --metric=disk_read_rate --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## Prometheus API

底层调用 Prometheus 的 `query_range` API：
- 地址：`http://localhost:9090/api/v1/query_range`
- 采样间隔：15s