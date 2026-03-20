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
   - `bin` 模式：本地二进制运行
   - `docker` 模式：Docker 容器运行（推荐）

2. **等用户回复后再执行对应命令**

3. **禁止默认使用 bin 模式，必须用户明确选择**

## 子命令

### build
构建 AiKv 二进制（使用本地 AiDb）
```bash
./scripts/build_bin.sh
```

### docker-build
构建 AiKv Docker 镜像（使用本地 AiDb）
```bash
./scripts/build_docker.sh
```

### run
启动 AiKv 服务（bin 模式）
```bash
./scripts/run_bin.sh
```

### docker-run
启动 AiKv Docker 容器
```bash
./scripts/run_docker.sh
```

### monitor
启动监控栈（Prometheus + Grafana + node-exporter + aikv-exporter）
```bash
./scripts/run_monitor.sh
```

### cleanup
清理 AiKv 资源（默认保留 Monitor 网络）
```bash
./scripts/cleanup.sh --force           # 仅清理 AiKv（保留 Monitor）
./scripts/cleanup.sh --all --force      # 清理全部（包括 Monitor）
```

## 使用示例

用户说"启动监控" → 执行 monitor
用户说"构建 AiKv" → 执行 build
用户说"运行服务" → **先询问 bin 还是 docker，等用户回复**
用户说"清理环境" → 执行 cleanup

## 强制询问规则

以下情况**必须**先询问模式：
- "启动 AiKv"
- "运行服务"
- "部署 AiKv"
- "帮我启动"
- 任何暗示启动服务的表述

询问方式：
```
请问使用哪种模式？
- bin: 本地二进制运行
- docker: Docker 容器运行（推荐）
```