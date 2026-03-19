# AiKv Workflow

AiDb/AiKv 调试工作流。

## 目录结构

```
Aikv-Workflow/
├── skills/
│   └── aikv-deployer/       # Skill
│       └── SKILL.md
│
├── agents/
│   └── aikv-deployer.md     # Agent
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

或手动复制：
- Skill: `skills/aikv-deployer/` → `~/.claude/skills/aikv-deployer/`
- Agent: `agents/aikv-deployer.md` → `~/.claude/agents/aikv-deployer.md`
