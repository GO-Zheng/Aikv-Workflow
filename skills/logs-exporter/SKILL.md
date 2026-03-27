---
name: logs-exporter
description: AiKv 日志导出工具
user-invocable: true
---

# Logs Exporter Skill

导出 AiKv 日志数据，供 AI 分析使用。

## 执行要求

**必须使用 Skill 工具调用本 Skill，执行其中的脚本命令。禁止绕过 Skill 直接执行 Bash 命令。**

## 脚本路径

脚本位于 `scripts/export_logs.sh`，会自动定位项目目录。

## 功能

- 导出指定时间范围内的 Loki 日志
- 支持按日志级别（ERROR/WARN/INFO/DEBUG）过滤
- 支持按服务名（job 标签）和主机名（host 标签）过滤
- 支持 JSON/CSV 格式输出
- 支持自定义时间范围

## 命令

### 列出可用标签
```bash
./scripts/export_logs.sh --list
```

### 导出最近日志（相对时间）
```bash
# 导出最近 5 分钟的所有日志
./scripts/export_logs.sh --duration=5m

# 导出最近 1 小时的日志
./scripts/export_logs.sh --duration=1h
```

### 导出指定时间范围的日志
```bash
# 导出今天 11:30 - 12:00 的日志
./scripts/export_logs.sh --start=11:30 --end=12:00

# 导出指定日期时间范围
./scripts/export_logs.sh --start="2026-03-26 11:30" --end="2026-03-26 12:00"

# 也支持 ISO 格式
./scripts/export_logs.sh --start="2026-03-26T11:30" --end="2026-03-26T12:00"
```

### 按日志级别过滤
```bash
# 只导出 ERROR 级别日志
./scripts/export_logs.sh --level=error --duration=30m

# 导出 ERROR 和 WARN 级别日志
./scripts/export_logs.sh --level=error,warn --duration=1h
```

### 按服务名过滤
```bash
# 只导出 aikv 服务的日志
./scripts/export_logs.sh --service=aikv --duration=30m

# 组合过滤：aikv 服务的 ERROR 日志
./scripts/export_logs.sh --service=aikv --level=error --duration=1h
```

### 按主机名过滤
```bash
# 只导出 aikv 主机的日志
./scripts/export_logs.sh --host=aikv --duration=30m
```

### 输出 CSV 格式
```bash
./scripts/export_logs.sh --level=error --duration=1h --format=csv
```

### 限制返回条数
```bash
# 最多返回 500 条
./scripts/export_logs.sh --level=error --duration=1h --limit=500
```

## 常用场景

| 场景 | 命令 |
|------|------|
| 查看最近所有日志 | `./scripts/export_logs.sh --duration=5m` |
| 查看 aikv 服务日志 | `./scripts/export_logs.sh --service=aikv --duration=30m` |
| 导出 CSV 给 AI 分析 | `./scripts/export_logs.sh --service=aikv --duration=1h --format=csv` |

## 注意事项

### 服务名 (--service)
AiKv 的 Promtail job 标签值为 `aikv`，所以应使用：
```bash
./scripts/export_logs.sh --service=aikv --duration=30m
```

### 日志级别过滤
日志中的级别是以 ANSI 颜色码格式记录的（如 `[32m INFO[0m`、`[31m ERROR[0m`），`--level` 参数通过字符串匹配过滤。如果级别过滤无效，可以直接用文本过滤：
```bash
# 过滤包含 ERROR 字样的日志行
./scripts/export_logs.sh --service=aikv-logs --level=error --duration=30m
```

## 分析日志时关注点

| 日志级别 | 关注原因 |
|----------|----------|
| ERROR | 服务异常、需要立即处理 |
| WARN | 潜在问题、性能下降、配置问题 |
| INFO | 正常操作记录、便于理解服务行为 |
| DEBUG | 详细调试信息、排查问题用 |

## 与 metrics-exporter 的配合

日志 + 指标组合分析：

```
指标分析：发现某个时间点 QPS 下降
   ↓
日志分析：同时段有什么 ERROR 日志？
   ↓
./scripts/export_logs.sh --start=14:30 --end=14:35 --level=error
```

## Loki API

底层调用 Loki 的 `query_range` API：
- 地址：`http://localhost:3100/loki/api/v1/query_range`
- 最大条数：5000 条
- 默认条数：1000 条
