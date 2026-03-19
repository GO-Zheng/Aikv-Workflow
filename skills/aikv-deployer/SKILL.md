---
name: aikv-deployer
description: AiKv 构建、部署、清理工作流
user-invocable: true
---

# AiKv Deployer Skill

单命令调用 AiKv 工作流脚本。

## 重要：启动前询问模式

**收到"启动 AiKv"、"运行服务"等指令时，必须先询问用户选择模式，再执行对应命令：**
- `bin` 模式：本地二进制运行
- `docker` 模式：Docker 容器运行（推荐）

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
启动 AiKv 服务
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
清理所有资源（data、logs、target、容器、镜像、网络）
```bash
./scripts/cleanup.sh --force
```

## 使用示例

用户说"启动监控" → 执行 monitor
用户说"构建 AiKv" → 执行 build
用户说"运行服务" → 执行 run
用户说"清理环境" → 执行 cleanup
