#!/bin/bash

# 安装 AiKv Skill/Agent 到编辑器
#
# 用法：
#   ./install.sh claude        # Claude Code
#   ./install.sh cursor        # Cursor
#   ./install.sh all           # 所有编辑器
#   ./install.sh --uninstall   # 卸载

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

install_claude_code() {
    echo "安装到 Claude Code..."
    mkdir -p ~/.claude/skills
    mkdir -p ~/.claude/agents

    # 复制 skills
    if [[ -d "$PROJECT_DIR/skills" ]]; then
        for skill in "$PROJECT_DIR/skills"/*/SKILL.md; do
            [[ -e "$skill" ]] || continue
            skill_name=$(basename "$(dirname "$skill")")
            mkdir -p ~/.claude/skills/"$skill_name"
            cp "$skill" ~/.claude/skills/"$skill_name"/
            echo "  安装 skill: $skill_name"
        done
    fi

    # 复制 agents
    if [[ -d "$PROJECT_DIR/agents" ]]; then
        for agent in "$PROJECT_DIR/agents"/*.md; do
            [[ -e "$agent" ]] || continue
            agent_name=$(basename "$agent" .md)
            cp "$agent" ~/.claude/agents/
            echo "  安装 agent: $agent_name"
        done
    fi

    echo "Claude Code 安装完成！"
}

install_cursor() {
    echo "安装到 Cursor..."
    mkdir -p ~/.cursor/skills

    # 复制 skills
    if [[ -d "$PROJECT_DIR/skills" ]]; then
        for skill in "$PROJECT_DIR/skills"/*/SKILL.md; do
            [[ -e "$skill" ]] || continue
            skill_name=$(basename "$(dirname "$skill")")
            mkdir -p ~/.cursor/skills/"$skill_name"
            cp "$skill" ~/.cursor/skills/"$skill_name"/
            echo "  安装 skill: $skill_name"
        done
    fi

    echo "Cursor 安装完成！"
}

uninstall() {
    echo "卸载 AiKv Skill/Agent..."

    # Claude Code
    rm -rf ~/.claude/skills/aikv-deployer
    rm -rf ~/.claude/agents/aikv-deployer.md

    # Cursor
    rm -rf ~/.cursor/skills/aikv-deployer

    echo "卸载完成！"
}

case "${1:-}" in
    claudio-code|claude)
        install_claude_code
        ;;
    cursor)
        install_cursor
        ;;
    all)
        install_claude_code
        install_cursor
        ;;
    --uninstall|-u)
        uninstall
        ;;
    --help|-h)
        echo "用法: $0 [claude|cursor|all] [--uninstall]"
        echo ""
        echo "参数:"
        echo "  claude    安装到 Claude Code"
        echo "  cursor    安装到 Cursor"
        echo "  all       安装到所有编辑器"
        echo "  --uninstall  卸载"
        echo ""
        echo "示例:"
        echo "  $0 claude    # 安装到 Claude Code"
        echo "  $0 all       # 安装到所有编辑器"
        echo "  $0 --uninstall # 卸载"
        ;;
    *)
        echo "未知参数: $1"
        echo "用法: $0 [claude|cursor|all] [--uninstall]"
        exit 1
        ;;
esac
