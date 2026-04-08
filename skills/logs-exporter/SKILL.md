---
name: logs-exporter
description: AiKv 日志导出工具
user-invocable: true
---

# Logs Exporter Skill

导出 AiKv 日志数据, 供 AI 分析使用。

## 执行要求

**必须使用 Skill 工具调用本 Skill, 执行其中的脚本命令。禁止绕过 Skill 直接执行 Bash 命令。**

## 脚本路径与前置条件

- 脚本：`Aikv-Workflow/scripts/export_logs.sh`（在仓库根下执行时需 `cd` 到 `Aikv-Workflow`）。
- **必须**存在 `Aikv-Workflow/docker/.env`，且包含 **`MONITOR_HOST`**（Loki 所在机，如 `192.168.1.112`）。脚本会 `source` 该文件并访问 `http://${MONITOR_HOST}:3100`。
- 无 `.env` 或缺少 `MONITOR_HOST` 时脚本会直接报错退出（不设默认值，避免拉到错误环境）。

## 功能

- 导出指定时间范围内的 Loki 日志（`query_range`）
- 按 **Promtail 提取的 JSON 字段** 过滤：`level`（标签）、`request_id`、`diag_event`（`| json | diag_event="..."`）
- 按 **job**（`--service`，一般为 `aikv`）、**service**（`--host`，容器名）缩小范围
- **`--contains`**：行级子串（LogQL `|=`），用于 AiDb `log::` 等**非结构化 JSON 行**里的 `diag_event=...`
- 支持 JSON/CSV 输出、`--limit`（默认 1000，上限 5000）

## 命令

### 列出可用标签
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --list
```

### 导出最近日志 (相对时间 ) 
```bash
# 导出最近 5 分钟的所有日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --duration=5m

# 导出最近 1 小时的日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --duration=1h
```

### 导出指定时间范围的日志
```bash
# 导出今天 11:30 - 12:00 的日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --start=11:30 --end=12:00

# 导出指定日期时间范围
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --start="2026-03-26 11:30" --end="2026-03-26 12:00"

# 也支持 ISO 格式
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --start="2026-03-26T11:30" --end="2026-03-26T12:00"
```

### 按日志级别过滤
```bash
# 只导出 ERROR 级别日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --level=error --duration=30m

# 导出 ERROR 和 WARN 级别日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --level=error,warn --duration=1h
```

### 按服务名过滤
```bash
# 只导出 aikv 服务的日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --service=aikv --duration=30m

# 组合过滤: aikv 服务的 ERROR 日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --service=aikv --level=error --duration=1h
```

### 按节点名过滤
```bash
# 只导出 aikv-master-1 节点的日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --host=aikv-master-1 --duration=30m

# 只导出 aikv-replica-1 节点的日志
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --host=aikv-replica-1 --duration=30m

# 导出所有节点的日志 (默认 ) 
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --duration=30m
```

### 输出 CSV 格式
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --level=error --duration=1h --format=csv
```

### 限制返回条数
```bash
# 最多返回 500 条
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --level=error --duration=1h --limit=500
```

### 按诊断事件 `diag_event` 过滤（推荐：排障时优先用）

AiKv 在 tracing JSON 中会写入稳定字段 **`diag_event`**，便于和指标异常时间段对齐，避免只靠全文搜索猜原因。

```bash
# 节点启动完成（核对 advertise_host、auto_failover、监听地址）
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --diag-event=cluster_node_listen_ready --duration=30m

# 客户端收到 ERR Storage / 写入失败链
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --diag-event=cluster_command_storage_err --duration=30m

# Raft 写路径：本机缺少对应 data group / ForwardToLeader 未解析
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --diag-event=cluster_raft_no_local_group --duration=30m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --diag-event=cluster_raft_forward_unparsed --duration=30m

# 指定容器 + 诊断事件
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --host=aikv-master-1 --diag-event=cluster_command_storage_err --duration=30m
```

**`diag_event` 速查表（AiKv / JSON）**

| `diag_event` | 含义 |
|--------------|------|
| `cluster_node_listen_ready` | 集群节点 Redis 侧就绪；含 `advertise_host`、`auto_failover` |
| `cluster_raft_forward_to_moved` | AiDb `ForwardToLeader` 已映射为 Redis `MOVED` |
| `cluster_raft_forward_unparsed` | 含 ForwardToLeader 但未能解析 leader 地址 |
| `cluster_raft_no_local_group` | 路由到的 Raft group 在本机无存储/实例 |
| `cluster_command_storage_err` | 命令路径返回 Storage 类错误（含 `command`、`client`、`error`） |
| `cluster_command_internal_err` | Internal 类错误 |
| `cluster_command_io_protocol_err` | Persistence / Protocol 错误 |
| `cluster_client_moved` | 返回 MOVED（一般为 **debug**，量大时别开太久窗口） |

### 按行子串 `--contains`（AiDb 等文本日志）

AiDb 侧使用 `log::warn!` / `log::error!` 输出 **`diag_event=...`** 子串，需用行过滤而不是 `| json`：

```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --contains=diag_event=db_write_batch_resync_retry --duration=30m
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --contains=diag_event=db_write_batch_no_group_after_sync --duration=30m
```

**注意**：`--contains` 的值**不要含双引号**；会与 LogQL 拼接。

### 按 `request-id` 过滤

当客户端或日志里带有同一 `request_id` 时：

```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --request-id=<id> --duration=1h
```

## 常用场景

| 场景 | 命令 |
|------|------|
| 查看最近所有日志 | `cd .../Aikv-Workflow && ./scripts/export_logs.sh --duration=5m` |
| 查看 aikv 服务日志 | `cd .../Aikv-Workflow && ./scripts/export_logs.sh --service=aikv --duration=30m` |
| 集群写入/ERR Storage 排障 | `cd .../Aikv-Workflow && ./scripts/export_logs.sh --diag-event=cluster_command_storage_err --duration=30m` |
| AiDb Raft 组缺失 | `cd .../Aikv-Workflow && ./scripts/export_logs.sh --contains=diag_event=db_write_batch --duration=30m` |
| 导出 CSV 给 AI 分析 | `cd .../Aikv-Workflow && ./scripts/export_logs.sh --service=aikv --duration=1h --format=csv` |

## 注意事项

### 服务名 (--service)
AiKv 的 Promtail job 标签值为 `aikv` (所有节点统一 ) , 所以应使用: 
```bash
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --service=aikv --duration=30m
```

### 节点名 (--host)
节点名对应 Promtail 的 `service` 标签, 值为容器名: 
- 单机模式: `aikv`
- 集群模式: `aikv-master-1`, `aikv-replica-1`, `aikv-master-2`, `aikv-replica-2`, `aikv-master-3`, `aikv-replica-3`

### 日志级别过滤 (`--level`)

当前流水线里 AiKv 容器日志为 **tracing JSON**，Promtail 会解析出 **`level` 标签**。`--level=error,warn` 会生成标签正则过滤（与正文 ANSI 颜色无关）。若某条日志不是 JSON 或未带 `level` 字段，可能不会被 `--level` 命中，可改用 **`--contains`** 或放宽时间窗口后人工看原始 JSON。

## 分析日志时关注点

| 日志级别 | 关注原因 |
|----------|----------|
| ERROR | 服务异常、需要立即处理 |
| WARN | 潜在问题、性能下降、配置问题 |
| INFO | 正常操作记录、便于理解服务行为 |
| DEBUG | 详细调试信息、排查问题用 |

## 与 metrics-exporter 的配合

日志 + 指标组合分析: 

```
指标分析: 发现某个时间点 QPS 下降
   ↓
日志分析: 同时段有什么 ERROR 日志？
   ↓
cd /root/code/wiqun/Aikv-Workflow && ./scripts/export_logs.sh --start=14:30 --end=14:35 --level=error
```

## Loki API

底层调用 Loki 的 `query_range` API：

- 地址：`http://${MONITOR_HOST}:3100/loki/api/v1/query_range`（`MONITOR_HOST` 来自 `docker/.env`）
- 最大条数：5000；默认：1000

## 排障技巧（与指标/测试对齐）

1. 用 **metrics-exporter** 确定异常时间段（例如延迟尖刺、QPS 掉底）。
2. 用 **相同起止时间** 拉日志：`--start` / `--end` 或 `--duration` 覆盖该窗口。
3. 先 **`--level=error,warn`**，再 **`--diag-event=...`** 缩小到具体链路；若怀疑 AiDb 层，加 **`--contains=diag_event=db_write_batch`**。
4. 分节点：`--host=aikv-master-1` 等与 Prometheus 上 `instance`/`node` 对应，便于和单点指标对齐。
5. **宿主脚本**（如 `init_cluster.sh`） stdout **默认不进 Loki**；初始化问题以 **容器内 AiKv 日志** + 终端输出一起对。
