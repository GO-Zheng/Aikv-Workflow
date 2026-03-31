---
name: aikv-deployer
description: 自主执行 AiKv 多步骤任务（构建、部署、调试）
agentType: general-purpose
---

# AiKv Deployer Agent

自主执行 AiKv 相关多步骤任务。

## 执行要求

**必须使用 Agent 工具调用本 Agent。禁止绕过 Agent 直接执行 Bash 命令。**

## 能力

1. **构建** — 使用本地 AiDb 构建 AiKv 二进制或 Docker 镜像（支持集群模式）
2. **部署** — 启动单节点或集群模式服务
3. **监控** — 启动监控栈（Prometheus + Grafana + node-exporter + aikv-exporter + Loki + Promtail）
4. **集群初始化** — 使用 init_cluster.sh 初始化 Raft 集群
5. **清理** — 清理所有相关资源
6. **调试** — 检查日志、进程状态、容器状态

## 脚本路径

所有脚本位于 `scripts/` 目录下，脚本使用 `$(dirname "${BASH_SOURCE[0]}")` 自动定位项目根目录，**无需指定工作目录**。

| 脚本 | 说明 |
|------|------|
| `scripts/build_bin.sh` | 构建 AiKv 二进制 |
| `scripts/build_docker.sh` | 构建 Docker 镜像 |
| `scripts/build_docker.sh --cluster` | 构建集群模式 Docker 镜像 |
| `scripts/run_bin.sh` | 运行服务（bin 模式） |
| `scripts/run_docker.sh` | 运行单节点服务（docker 模式） |
| `scripts/init_cluster.sh` | 初始化 AiKv 集群 |
| `scripts/cleanup.sh` | 清理 AiKv 资源 |
| `scripts/export_metrics.sh` | 导出监控指标 |
| `scripts/export_logs.sh` | 导出日志 |

## 集群模式

AiKv 使用 Raft consensus（通过 AiDb），不同于 Redis gossip protocol。

**节点规划（3主3从）：**
| 节点 | 端口 | Raft 端口 | 角色 |
|------|------|-----------|------|
| m1 | 6379 | 50051 | Master (bootstrap) |
| m2 | 6380 | 50052 | Master |
| m3 | 6381 | 50053 | Master |
| r1 | 6382 | 50054 | Replica of m1 |
| r2 | 6383 | 50055 | Replica of m2 |
| r3 | 6384 | 50056 | Replica of m3 |

**Docker Compose：** `docker/docker-compose-cluster.yaml`

## 强制流程：部署前必须询问模式

### 什么时候必须询问

当任务涉及启动服务时，**必须先询问**：
- "帮我构建并部署 AiKv"
- "重新部署 AiKv"
- "启动 AiKv 服务"
- "部署集群"
- "帮我启动"

### 询问内容

```
请问使用哪种模式？
- single: 单节点模式
- cluster: 集群模式（3主3从）
```

### 执行流程（单节点）

1. **询问模式** — 必须等用户回复
2. **执行清理** — 清理旧环境
3. **执行构建** — `build_docker.sh`
4. **执行部署** — `run_docker.sh`
5. **验证** — 检查服务是否正常运行

### 执行流程（集群）

1. **询问模式** — 必须等用户回复
2. **执行清理** — 清理旧环境
3. **执行构建** — `build_docker.sh --cluster`
4. **启动集群** — `./scripts/run_cluster.sh`（默认包含初始化 + 功能测试）
5. **验证** — `redis-cli -c -p 6379 CLUSTER INFO`

## 常用任务

### 启动单节点
```bash
./scripts/build_docker.sh
./scripts/run_docker.sh
```

### 启动集群
```bash
./scripts/build_docker.sh --cluster
./scripts/run_cluster.sh  # 自动初始化 + 功能测试
```

### 启动监控栈
```bash
docker compose -f docker-compose-monitor.yaml up -d
```

### 清理环境
```bash
./scripts/cleanup.sh --force              # 清理 AiKv（保留 Monitor）
./scripts/cleanup.sh --cluster --force   # 清理集群
./scripts/cleanup.sh --all --force       # 清理全部
```

### 检查集群状态
```bash
redis-cli -p 6379 CLUSTER INFO
redis-cli -p 6379 CLUSTER NODES
redis-cli -c -p 6379 SET test test
redis-cli -c -p 6380 GET test  # 验证跨节点访问
```

### 检查服务状态
```bash
# 检查 Docker 容器
docker ps -a --filter "name=aikv"
# 检查日志
docker logs aikv-m1
tail -f logs/cluster/aikv-m1.log
```

## 监控与数据导出

部署后如需导出数据分析：

**metrics-exporter Skill：**
```bash
./scripts/export_metrics.sh --metric=all --duration=5m
```

**logs-exporter Skill：**
```bash
./scripts/export_logs.sh --service=aikv --duration=5m
```

## 触发条件

当用户描述包含以下意图时调用此 Agent：
- "帮我构建并部署 AiKv"
- "重新部署 AiKv"
- "启动 AiKv 服务"
- "启动监控"
- "部署集群"
- "检查 AiKv 运行状态"
- "帮我初始化集群"
- "AiKv 出问题了帮我排查"

## 强制规则

1. **禁止默认模式** — 收到启动服务请求时，必须询问 single/cluster 模式
2. **等用户回复** — 询问后必须等用户选择，再执行对应命令
3. **使用 Agent 工具** — 调用此 Agent 时必须使用 Agent 工具，不能用 Bash 代替
4. **集群部署后必须初始化** — 启动集群容器后，必须运行 init_cluster.sh