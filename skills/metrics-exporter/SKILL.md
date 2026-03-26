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
./scripts/export_metrics.sh --list
```

### 导出单个指标（相对时间）
```bash
# 导出最近 5 分钟的 User CPU
./scripts/export_metrics.sh --metric=redis_cpu_user_seconds_total --duration=5m

# 导出最近 1 小时
./scripts/export_metrics.sh --metric=redis_cpu_sys_seconds_total --duration=1h
```

### 导出单个指标（绝对时间）
```bash
# 导出今天 11:30 - 12:00 的 OPS
./scripts/export_metrics.sh --metric=ops --start=11:30 --end=12:00

# 导出指定日期时间范围
./scripts/export_metrics.sh --metric=all --start="2026-03-26 11:30" --end="2026-03-26 12:00"

# 也支持 ISO 格式
./scripts/export_metrics.sh --metric=ops --start="2026-03-26T11:30" --end="2026-03-26T12:00"
```

### 导出所有 CPU 指标
```bash
./scripts/export_metrics.sh --metric=all_cpu --duration=30m
```

### 导出所有 AiKv 指标
```bash
./scripts/export_metrics.sh --metric=all --duration=5m
```

### 输出 CSV 格式
```bash
./scripts/export_metrics.sh --metric=all_cpu --duration=1h --format=csv
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
| aidb_memtable_bytes | MemTable 大小 | AiDb MemTable |
| aidb_wal_bytes | WAL 大小 | AiDb WAL |
| aidb_block_cache_bytes | Block Cache 使用量 | AiDb Block Cache |
| aidb_block_cache_capacity_bytes | Block Cache 容量 | AiDb Block Cache |
| qps | 读命令 QPS | QPS/OPS |
| ops | 所有命令 OPS | QPS/OPS |
| redis_commands_total | 按命令类型的统计 | 命令类型分布 |
| command_ratio | 各命令占比 (0-1) | 命令类型占比 |
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
./scripts/export_metrics.sh --metric=all_cpu --duration=5m
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析 QPS/OPS

1. 导出数据：
```bash
# 导出 QPS 和 OPS
./scripts/export_metrics.sh --metric=qps --duration=5m
./scripts/export_metrics.sh --metric=ops --duration=5m

# 导出指定时间范围
./scripts/export_metrics.sh --metric=ops --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析命令类型分布

1. 导出各命令类型的 QPS：
```bash
# 导出所有命令类型的趋势
./scripts/export_metrics.sh --metric=redis_commands_total --duration=5m

# 导出指定时间范围
./scripts/export_metrics.sh --metric=redis_commands_total --start=11:30 --end=12:00
```

2. 将 JSON 输出发送给 AI 分析

## 示例：分析命令占比（饼图）

1. 导出各命令占比（已计算好百分比）：
```bash
# 导出当前各命令占比
./scripts/export_metrics.sh --metric=command_ratio --duration=5m

# 导出指定时间范围
./scripts/export_metrics.sh --metric=command_ratio --start=11:30 --end=12:00
```

2. 直接返回每个命令的占比 (0-1)，无需 AI 自行计算

## Prometheus API

底层调用 Prometheus 的 `query_range` API：
- 地址：`http://localhost:9090/api/v1/query_range`
- 采样间隔：15s