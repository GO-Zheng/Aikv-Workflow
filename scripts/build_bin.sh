#!/bin/bash

# 构建脚本：使用本地 AiDb 依赖构建 AiKv
#
# 用法：
#   ./build_by_local_aidb.sh            # debug 模式(默认)
#   ./build_by_local_aidb.sh --release  # release 模式
#   ./build_by_local_aidb.sh --cluster  # 启用集群功能(debug)
#   ./build_by_local_aidb.sh --release --cluster # release + 集群
#
# 参数说明：
#   --release  生产优化模式(-O3), 编译慢但运行快
#   --cluster  启用 Raft 集群功能(需要额外依赖 openraft, tonic)
#
# 默认：cargo build(debug 模式, 编译快, 调试友好)

set -e

AIDB_GIT="aidb = { git = \"https://github.com/wiqun/AiDb\", tag = \"v0.7.0\" }"
AIDB_PATH='aidb = { path = "../AiDb" }'
CARGO_TOML="/root/code/Flow/AiKv/Cargo.toml"

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

echo "=== 开始构建：切换到本地 AiDb 依赖 ==="
echo "构建命令: $BUILD_CMD"

# 1. 修改 Cargo.toml, 切换到本地路径依赖
echo "修改 Cargo.toml: 切换 aidb 为本地路径依赖..."
sed -i "s|$AIDB_GIT|$AIDB_PATH|" "$CARGO_TOML"

# 2. 执行构建
echo "执行构建..."
cd /root/code/Flow/AiKv
eval "$BUILD_CMD"

# 3. 恢复原始 Cargo.toml
echo "恢复 Cargo.toml: 还原为 Git 依赖..."
sed -i "s|$AIDB_PATH|$AIDB_GIT|" "$CARGO_TOML"

# 4. 复制产物到 Aikv-Workflow/target
TARGET_DIR="/root/code/Flow/Aikv-Workflow/target"
if [[ "$BUILD_CMD" == *"release"* ]]; then
    SOURCE_BIN="/root/code/Flow/AiKv/target/release/aikv"
else
    SOURCE_BIN="/root/code/Flow/AiKv/target/debug/aikv"
fi
echo "复制产物到 $TARGET_DIR/ ..."
cp "$SOURCE_BIN" "$TARGET_DIR/"

echo "=== 构建完成 ==="
echo "产物位置: $TARGET_DIR/aikv"
