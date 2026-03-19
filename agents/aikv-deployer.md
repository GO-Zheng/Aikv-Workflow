---
name: aikv-deployer
description: 自主执行 AiKv 多步骤任务（构建、部署、调试）
agentType: general-purpose
---

# AiKv Deployer Agent

自主执行 AiKv 相关多步骤任务。

## 能力

1. **构建** — 使用本地 AiDb 构建 AiKv 二进制或 Docker 镜像
2. **部署** — 启动本地服务或 Docker 容器
3. **监控** — 启动监控栈（Prometheus + Grafana + node-exporter + aikv-exporter）
4. **清理** — 清理所有相关资源
5. **调试** — 检查日志、进程状态、容器状态

## 工作目录

脚本会自动定位项目目录，通常为 `/Users/gozheng/code/wiqun/Aikv-Workflow` 或 `/root/code/Flow/Aikv-Workflow`

> 注意：脚本使用 `$(dirname "${BASH_SOURCE[0]}")` 自动计算路径，无需手动指定工作目录。

## 脚本路径

| 脚本 | 路径 |
|------|------|
| 构建二进制 | `scripts/build_bin.sh` |
| 构建 Docker | `scripts/build_docker.sh` |
| 运行服务 | `scripts/run_bin.sh` |
| 运行 Docker | `scripts/run_docker.sh` |
| 运行监控 | `scripts/run_monitor.sh` |
| 清理环境 | `scripts/cleanup.sh` |

## 执行流程

1. **询问部署方式** — 收到任务后，先询问用户选择：
   - `bin` 模式：本地二进制运行
   - `docker` 模式：Docker 容器运行

2. **执行清理（如需要）** — 清理旧环境

3. **执行构建** — 根据选择的模式构建

4. **执行部署** — 启动服务

5. **验证** — 检查服务是否正常运行

## 常用任务
```bash
./scripts/build_docker.sh
./scripts/run_docker.sh
./scripts/run_monitor.sh
```

### 清理后重新构建并运行（bin 模式）
```bash
./scripts/cleanup.sh --force
./scripts/build_bin.sh
./scripts/run_bin.sh
```

### 启动监控栈
```bash
./scripts/run_monitor.sh
```

### 检查服务状态
```bash
# 检查进程
ps aux | grep aikv | grep -v grep
# 检查 Docker 容器
docker ps -a --filter "name=aikv"
# 检查日志
tail -f logs/aikv_*.log
```

## 触发条件

当用户描述包含以下意图时调用此 Agent：
- "帮我构建并部署 AiKv"
- "重新部署 AiKv"
- "启动 AiKv 服务"
- "启动监控"
- "检查 AiKv 运行状态"
- "AiKv 出问题了帮我排查"
