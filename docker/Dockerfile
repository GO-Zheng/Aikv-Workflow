# syntax=docker/dockerfile:1
# ============================================================
# AiKv Dockerfile - 使用本地 AiDb
#
# 加速说明：
# - 先用占位 main 编译依赖，再 COPY 真实 src，仅业务代码变更时跳过依赖重编
# - BuildKit 挂载 cargo registry/git 缓存，跨次构建复用已下载的 crate
# - 调试可加 --build-arg PROFILE=dev（配合 build_docker.sh --dev），debug 编译远快于 release
# ------------------------------------------------------------

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

ARG FEATURES=""
# release | dev — dev 用于本地调试迭代，编译快很多
ARG PROFILE=release

# 复制 AiDb 代码（从上级目录）
COPY ../AiDb ./AiDb

# 复制 AiKv 清单与 bench 元数据（先于源码，利于层缓存）
COPY ../AiKv/Cargo.toml ../AiKv/Cargo.lock ./
COPY ../AiKv/benches ./benches

# 修改 Cargo.toml 使用本地 AiDb（须在首次 cargo build 之前）
RUN sed -i 's|aidb = { .*git.*github.com/wiqun/AiDb.* }|aidb = { path = "./AiDb" }|; s|aidb = { path = "\.\./AiDb" }|aidb = { path = "./AiDb" }|' Cargo.toml

# 占位源码：仅用于把「依赖 + aidb」编译进独立层；勿在此之后改 Cargo.toml/AiDb 顺序
RUN mkdir -p src && echo "fn main() {}" > src/main.rs

# 第一次构建：拉取并编译所有依赖（源码仅为空 main）
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    if [ "$PROFILE" = "dev" ]; then \
      if [ -n "$FEATURES" ]; then cargo build --features "$FEATURES" --bin aikv; \
      else cargo build --bin aikv; fi; \
    else \
      if [ -n "$FEATURES" ]; then cargo build --release --features "$FEATURES" --bin aikv; \
      else cargo build --release --bin aikv; fi; \
    fi

# 真实业务源码（仅改 src 时上面层可命中缓存）
COPY ../AiKv/src ./src

# 第二次构建：通常只重编 aikv 自身
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    if [ "$PROFILE" = "dev" ]; then \
      if [ -n "$FEATURES" ]; then cargo build --features "$FEATURES" --bin aikv; \
      else cargo build --bin aikv; fi; \
    else \
      if [ -n "$FEATURES" ]; then cargo build --release --features "$FEATURES" --bin aikv; \
      else cargo build --release --bin aikv; fi; \
    fi

# release 缩小体积；产物统一到固定路径供 runtime COPY（dev 对应 target/debug）
RUN if [ "$PROFILE" = "release" ]; then \
      strip target/release/aikv && cp target/release/aikv /aikv-artifact; \
    else \
      cp target/debug/aikv /aikv-artifact; \
    fi

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

# 从编译阶段拷贝产物（见 builder 末尾 /aikv-artifact）
COPY --from=builder /aikv-artifact ./aikv
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
