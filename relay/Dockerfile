# relay 容器 = 自编译 sing-box（带 with_v2ray_api，官方镜像没有）+ 订阅服务。
# 构建上下文是仓库根目录：docker compose -f relay/docker-compose.yml build
# 网络差时：--build-arg GOPROXY=https://goproxy.io,direct（或 goproxy.cn）；或干脆用 CI 推到 GHCR 的现成镜像（RELAY_IMAGE）。
ARG SING_BOX_VERSION=1.14.3
ARG GOPROXY=https://proxy.golang.org,direct

FROM golang:1.26-alpine AS builder
ARG SING_BOX_VERSION
ARG GOPROXY
ENV GOPROXY=${GOPROXY} CGO_ENABLED=0
RUN apk add --no-cache git ca-certificates
WORKDIR /src
RUN git clone --depth 1 --branch "v${SING_BOX_VERSION}" https://github.com/SagerNet/sing-box.git .
# 先把依赖拉全（失败重试 5 次），再编译；弱网下避免编译到一半因为下载超时失败
RUN for i in 1 2 3 4 5; do go mod download && break; echo "go mod download 第 $i 次失败，10 秒后重试"; sleep 10; done && go mod download
# tag 以官方 release/DEFAULT_BUILD_TAGS_OTHERS 为准裁剪：1.14 起 with_reality_server 已并入 with_utls，再传会报错；
# badlinkname / tfogo_checklinkname0 与 -checklinkname=0 是上游依赖用 go:linkname 所需（release/LDFLAGS）。
# -p 1：限制并行编译，1 GB 内存的 VPS 配合 swap 不会 OOM
RUN go build -p 1 -trimpath \
    -tags with_quic,with_utls,with_acme,with_clash_api,with_v2ray_api,badlinkname,tfogo_checklinkname0 \
    -ldflags "-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
    -o /sing-box ./cmd/sing-box

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata curl wireguard-tools \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /sing-box /usr/local/bin/sing-box
WORKDIR /app
COPY subscribe/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY subscribe/app ./app
COPY subscribe/templates ./templates
COPY subscribe/pa /usr/local/bin/pa
RUN chmod +x /usr/local/bin/pa
CMD ["python", "-m", "app.main"]
