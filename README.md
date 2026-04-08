# AiKv Workflow

AiDb/AiKv 调试工作流。

## 仓库布局（必读）

本仓库脚本默认与 **AiKv**、**AiDb** 位于**同一父目录**下并列，例如：

- `.../wiqun/Aikv-Workflow`
- `.../wiqun/AiKv`
- `.../wiqun/AiDb`

构建镜像时 [scripts/build_docker.sh](scripts/build_docker.sh) 使用**父目录**为 Docker 上下文（`docker build ... ..`），[docker/Dockerfile](docker/Dockerfile) 通过 `COPY ../AiDb`、`COPY ../AiKv/...` 引用二者。若目录不同，需自行改脚本或上下文路径。

工具链：工作流镜像构建使用 `rust:1.92-bookworm`；[AiDb/deploy/Dockerfile](../AiDb/deploy/Dockerfile) 使用 `rust:1.91-bullseye`，二者用途不同，无需强制一致，但全仓本地开发时建议使用不低于工作流镜像的 Rust 版本以免出现编译差异。

文档与 Skills 中的示例路径多为 `cd /root/code/wiqun/Aikv-Workflow`：**请替换为你的本机路径**，或先 `cd` 到本仓库根目录再执行相对路径 `./scripts/...`。

与上游 AiKv 仓库根目录 [Dockerfile](https://github.com/Genuineh/AiKv) 的差异：上游镜像默认拷贝仓库根的 `aikv.toml`；本工作流 [docker/Dockerfile](docker/Dockerfile) 拷贝构建上下文下的 **`AiKv/config/aikv.toml`**，与仓库内集群配置目录约定一致。

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
- Skill: `skills/aikv-deployer/` → `~/.claude/skills/aikv-deployer/`（Cursor: `~/.cursor/skills/aikv-deployer/`）
- Agent: `agents/*.md` → `~/.claude/agents/`（Cursor: `~/.cursor/agents/`，`install.sh cursor` 会一并安装）
