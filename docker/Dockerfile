# ============================================================
# AiKv Dockerfile - 使用本地 AiDb
# ============================================================

# ------------------------------------------------------------
# Stage 1: Builder - 编译阶段
# ------------------------------------------------------------
FROM rust:1.92-bookworm AS builder

# 启用 BuildKit 缓存加速
ENV CARGO_HOME=/usr/local/cargo
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

# 安装编译依赖
RUN apt-get update && apt-get install -y \
    cmake \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 复制 AiDb 代码（从上级目录）
COPY ../AiDb ./AiDb

# 复制 AiKv 代码（从上级目录）
COPY ../AiKv/Cargo.toml ../AiKv/Cargo.lock ./
COPY ../AiKv/benches ./benches
RUN mkdir src && echo "fn main() {}" > src/main.rs

# 复制 AiKv 源码
COPY ../AiKv/src ./src

# 修改 Cargo.toml 使用本地 AiDb
RUN sed -i 's|aidb = { git = "https://github.com/wiqun/AiDb", tag = "v0.7.0" }|aidb = { path = "./AiDb" }|' Cargo.toml

# 编译
ARG FEATURES=""
RUN cargo build --release ${FEATURES:+--features $FEATURES} --bin aikv

# 移除调试符号
RUN strip target/release/aikv

# ------------------------------------------------------------
# Stage 2: Runtime - 极简运行环境
# ------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# 安装运行时必要组件
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    redis-tools \
    && rm -rf /var/lib/apt/lists/*

# 创建非 root 安全用户
RUN groupadd --gid 1000 aikv && \
    useradd --uid 1000 --gid aikv --shell /bin/bash --create-home aikv

WORKDIR /app

# 从编译阶段拷贝产物
COPY --from=builder /app/target/release/aikv ./aikv
COPY ../AiKv/config/aikv.toml ./aikv.toml

# 权限设置
RUN chown -R aikv:aikv /app
USER aikv

# 端口与健康检查
EXPOSE 6379
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD redis-cli PING | grep -q "PONG" || exit 1

ENTRYPOINT ["/app/aikv"]
CMD ["--config", "/app/aikv.toml"]
