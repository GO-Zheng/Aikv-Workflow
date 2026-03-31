---
name: aikv-deployer
description: AiKv 构建、部署、清理工作流
user-invocable: true
---

# AiKv Deployer Skill

单命令调用 AiKv 工作流脚本。

## 执行要求

**必须使用 Skill 工具调用本 Skill，执行其中的脚本命令。禁止绕过 Skill 直接执行 Bash 命令。**

## 重要：启动前必须询问模式

**收到"启动 AiKv"、"运行服务"、"部署 AiKv"等指令时：**

1. **必须先询问用户选择模式**：
   - `single`: 单节点模式（docker）
   - `cluster`: 集群模式（3主3从，docker）

2. **等用户回复后再执行对应命令**

3. **禁止默认使用任何模式，必须用户明确选择**

## 子命令

### build
构建 AiKv 二进制（使用本地 AiDb）
```bash
./scripts/build_bin.sh
```

### docker-build
构建 AiKv Docker 镜像（使用本地 AiDb）
```bash
./scripts/build_docker.sh --cluster  # 集群模式镜像
```

### docker-run-single
启动 AiKv 单节点 Docker 容器
```bash
./scripts/run_docker.sh
```

### docker-run-cluster
启动 AiKv 集群（3主3从 Docker 容器，默认会初始化并测试）
```bash
./scripts/run_cluster.sh           # 启动并初始化 + 功能测试（默认）
./scripts/run_cluster.sh --no-init # 仅启动（不初始化）
./scripts/run_cluster.sh --stop    # 停止
```

### cluster-init
初始化 AiKv 集群（启动集群后必须执行）
```bash
./scripts/init_cluster.sh
```

### cluster-status
查看集群状态
```bash
redis-cli -p 6379 CLUSTER INFO
redis-cli -p 6379 CLUSTER NODES
```

### monitor
启动监控栈（Prometheus + Grafana + node-exporter + aikv-exporter + Loki + Promtail）
```bash
docker compose -f docker-compose-monitor.yaml up -d
```

### cleanup
清理 AiKv 资源
```bash
./scripts/cleanup.sh --force            # 仅清理 AiKv（保留 Monitor）
./scripts/cleanup.sh --cluster --force  # 清理集群
./scripts/cleanup.sh --all --force      # 清理全部（包括 Monitor）
```

## 集群模式说明

集群模式部署 6 节点 AiKv：
- Master 1: 127.0.0.1:6379
- Master 2: 127.0.0.1:6380
- Master 3: 127.0.0.1:6381
- Replica 1: 127.0.0.1:6382 (of m1)
- Replica 2: 127.0.0.1:6383 (of m2)
- Replica 3: 127.0.0.1:6384 (of m3)

**集群部署流程：**
1. 构建集群镜像：`./scripts/build_docker.sh --cluster`
2. 启动并初始化：`./scripts/run_cluster.sh`（自动初始化 + 功能测试）
3. 验证集群：`redis-cli -c -p 6379 CLUSTER INFO`

## 使用示例

用户说"启动监控" → 执行 monitor
用户说"构建集群镜像" → 执行 docker-build with --cluster
用户说"部署集群" → **先询问，确认后执行 docker-run-cluster + cluster-init**
用户说"清理环境" → 执行 cleanup

## 强制询问规则

以下情况**必须**先询问模式：
- "启动 AiKv"
- "运行服务"
- "部署 AiKv"
- "部署集群"
- "帮我启动"
- 任何暗示启动服务的表述

询问方式：
```
请问使用哪种模式？
- single: 单节点模式
- cluster: 集群模式（3主3从）
```