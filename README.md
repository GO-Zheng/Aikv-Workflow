# AiKv Workflow

AiDb/AiKv 调试工作流。

## 目录结构

说明与排障以 **`skills/`**（如 `logs-exporter`、`metrics-exporter`、`aikv-deployer`）和 **`agents/`** 为准；**不单独维护 `docs/`**，避免与高频改动的脚本脱节。

```
Aikv-Workflow/
├── skills/
│   ├── aikv-deployer/       # 构建/部署/清理
│   ├── logs-exporter/       # Loki 日志导出与排障约定
│   └── metrics-exporter/    # Prometheus 指标导出
│
├── agents/
│   ├── aikv-deployer.md     # 部署 Agent
│   └── aikv-analyzer.md     # 指标分析 Agent
│
├── scripts/
│   ├── build_bin.sh          # 构建二进制
│   ├── build_docker.sh       # 构建 Docker 镜像
│   ├── cleanup.sh            # 清理环境
│   ├── run_bin.sh            # 运行服务
│   ├── run_docker.sh         # 运行 Docker
│   └── install.sh            # 安装脚本
│
├── config/
│   └── aikv.toml             # 配置文件
│
├── data/                      # 数据目录
├── logs/                      # 日志目录
└── target/                    # 编译产物
```

## 安装 Skills/Agents

使用安装脚本：
```bash
./scripts/install.sh claude     # 安装到 Claude Code
./scripts/install.sh cursor     # 安装到 Cursor
./scripts/install.sh all       # 安装到所有编辑器
./scripts/install.sh --uninstall # 卸载
```

或手动复制（按需增加 `logs-exporter`、`metrics-exporter` 等目录）：
- Skill: `skills/aikv-deployer/` → `~/.claude/skills/aikv-deployer/`
- Agent: `agents/aikv-deployer.md` → `~/.claude/agents/aikv-deployer.md`
