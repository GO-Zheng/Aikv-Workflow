#!/bin/bash

# 构建脚本：使用本地 AiDb 依赖构建 AiKv
#
# 用法：
#   ./build_bin.sh            # debug 模式(默认)
#   ./build_bin.sh --release  # release 模式
#   ./build_bin.sh --cluster  # 启用集群功能(debug)
#   ./build_bin.sh --release --cluster # release + 集群
#
# 参数说明：
#   --release  生产优化模式(-O3), 编译慢但运行快
#   --cluster  启用 Raft 集群功能(需要额外依赖 openraft, tonic)
#
# 默认：cargo build(debug 模式, 编译快, 调试友好)

set -e

# 自动定位项目目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_DIR="$(dirname "$SCRIPT_DIR")"
AIKV_DIR="$(dirname "$WORKFLOW_DIR")/AiKv"

# 与 AiDb 发布 tag 对齐（恢复 git 依赖时用此行；若上游无对应 tag 请改 tag 或改用 branch/rev）
AIDB_GIT='aidb = { git = "https://github.com/wiqun/AiDb", tag = "v0.7.2" }'
AIDB_PATH='aidb = { path = "../AiDb" }'
CARGO_TOML="$AIKV_DIR/Cargo.toml"

# 解析参数
BUILD_CMD="cargo build"
WHILE_LOOP=true

while $WHILE_LOOP; do
    case "${1:-}" in
        --release)
            BUILD_CMD="cargo build --release"
            shift
            ;;
        --cluster)
            BUILD_CMD="$BUILD_CMD --features cluster"
            shift
            ;;
        --help|-h)
            echo "用法: $0 [--release] [--cluster]"
            echo ""
            echo "参数:"
            echo "  --release  生产优化模式(-O3), 编译慢但运行快"
            echo "  --cluster  启用 Raft 集群功能"
            echo ""
            echo "示例:"
            echo "  $0              # debug 模式(默认)"
            echo "  $0 --release    # release 模式"
            echo "  $0 --cluster    # 集群模式(debug)"
            echo "  $0 --release --cluster # release + 集群"
            exit 0
            ;;
        *)
            WHILE_LOOP=false
            ;;
    esac
done

echo "=== 开始构建 ==="
echo "工作流目录: $WORKFLOW_DIR"
echo "AiKv 目录: $AIKV_DIR"
echo "构建命令: $BUILD_CMD"

# 1. 检查当前依赖状态并决定是否需要切换
if grep -q 'aidb = { path = "../AiDb" }' "$CARGO_TOML"; then
    # 已经是本地路径依赖，直接构建
    echo "检测到 Cargo.toml 已使用本地 AiDb 路径依赖"
    NEED_SWAP=false
elif grep -qE 'aidb = \{ git = "https://github.com/wiqun/AiDb"' "$CARGO_TOML"; then
    # 使用 Git 依赖（任意 tag/branch/rev），切换到本地路径
    echo "切换 Cargo.toml: Git 依赖 -> 本地路径依赖..."
    sed -i -E 's|^aidb = \{ git = "https://github.com/wiqun/AiDb"[^}]*\}|'"$AIDB_PATH"'|' "$CARGO_TOML"
    NEED_SWAP=true
else
    echo "警告: 无法识别 aidb 依赖类型，跳过依赖切换"
    NEED_SWAP=false
fi

# 2. 执行构建
echo "执行构建..."
cd "$AIKV_DIR"
eval "$BUILD_CMD"

# 3. 如果之前切换了依赖，则恢复原始状态
if $NEED_SWAP; then
    echo "恢复 Cargo.toml: 本地路径依赖 -> Git 依赖..."
    sed -i 's#^aidb = { path = "../AiDb" }#'"$AIDB_GIT"'#' "$CARGO_TOML"
fi

# 4. 复制产物到 Aikv-Workflow/target
TARGET_DIR="$WORKFLOW_DIR/target"
if [[ "$BUILD_CMD" == *"release"* ]]; then
    SOURCE_BIN="$AIKV_DIR/target/release/aikv"
else
    SOURCE_BIN="$AIKV_DIR/target/debug/aikv"
fi
echo "复制产物到 $TARGET_DIR/ ..."
cp "$SOURCE_BIN" "$TARGET_DIR/"

echo "=== 构建完成 ==="
echo "产物位置: $TARGET_DIR/aikv"
