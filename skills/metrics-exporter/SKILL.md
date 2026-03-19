---
name: metrics-exporter
description: AiKv 监控指标导出工具
user-invocable: true
---

# Metrics Exporter Skill

导出 AiKv 监控指标数据，供 AI 分析使用。

## 脚本路径

```
/root/code/Flow/Aikv-Workflow/scripts/export_metrics.sh
```

## 功能

- 导出指定时间范围内的 Prometheus 指标
- 支持 JSON/CSV 格式输出
- 支持自定义时间范围

## 命令

### 列出可用指标
```bash
./scripts/export_metrics.sh --list
```

### 导出单个指标
```bash
# 导出最近 5 分钟的 User CPU
./scripts/export_metrics.sh --metric=redis_cpu_user_seconds_total --duration=5m

# 导出最近 1 小时
./scripts/export_metrics.sh --metric=redis_cpu_sys_seconds_total --duration=1h
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

| 指标名 | 说明 |
|--------|------|
| redis_cpu_sys_seconds_total | 系统 CPU 时间 |
| redis_cpu_user_seconds_total | 用户 CPU 时间 |
| all_cpu | 所有 CPU 相关指标 |
| all | 所有可用指标 |

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

## Prometheus API

底层调用 Prometheus 的 `query_range` API：
- 地址：`http://localhost:9090/api/v1/query_range`
- 采样间隔：15s
