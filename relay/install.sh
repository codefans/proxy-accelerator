#!/usr/bin/env bash
# 入口中转 VPS 一键部署：relay 容器（自编译 sing-box + 订阅服务）+ Caddy + WireGuard 服务端 + nftables
# 适用：Debian 12 / Ubuntu 22.04+，root 运行。首次约 10 分钟（大头是编译 sing-box）。可重复运行（复用已生成的密钥与用户）。
# 需要整个仓库（relay/ 与 subscribe/ 同级）。
#
# 用法：
#   bash install.sh                                          # 自签证书，客户端 skip-cert-verify
#   DOMAIN=relay.example.com EMAIL=me@x.com bash install.sh  # Let's Encrypt：先把 A 记录指到本机（Cloudflare 灰云）
#   SUB_DOMAIN=sub.example.com bash install.sh               # 订阅域名（Cloudflare 橙云 → 本机 2053），决定 pa url 打印的地址
#   TG_BOT_TOKEN=123:abc TG_CHAT_ID=456 bash install.sh      # Telegram 告警；再加 BACKUP_TO_TELEGRAM=1 每日备份也发过去
#   bash install.sh --restore /path/pa-backup-xxx.tar.gz     # 在新 VPS 上用备份重建：密钥、用户、节点全部沿用，用户订阅地址不变
#   TAILSCALE=1 bash install.sh                              # 装 Tailscale（装完手动 tailscale up --ssh 登录一次）
#   SSH_VIA_TAILSCALE=1 bash install.sh                      # 公网不再开 SSH，只允许 tailscale0 进（要求 Tailscale 已登录且能连上）
#   RELAY_IMAGE=ghcr.io/<用户>/proxy-accelerator-relay:1.14.3 bash install.sh   # 直接拉 CI 构建好的镜像，不在 VPS 上编译（推荐）
#   GOPROXY=https://goproxy.io,direct bash install.sh        # 本机编译但 Go 下载慢时换代理
# 安全默认：装 fail2ban（sshd）与 unattended-upgrades（只装安全更新）；root 已有 authorized_keys 时关闭密码登录
# 可选环境变量（都有默认值）：
#   HY2_PH_PORT=443 VLESS_PH_PORT=443 HY2_HK_PORT=8443 VLESS_HK_PORT=8443 HOP_PORTS=20000-30000
#   UP_MBPS=50 DOWN_MBPS=50          # 填宿舍晚高峰实测上行 × 0.8，决定 Hysteria2 拥塞控制
#   WG_PORT=51820 SSH_PORT=<自动探测> REALITY_SNI=www.microsoft.com SNI=www.bing.com
#   SING_BOX_VERSION=1.14.3 ADMIN_USER=admin
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请以 root 运行" >&2; exit 1; }

RESTORE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore) RESTORE="${2:?--restore 需要备份文件路径}"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$RESTORE" || -f "$RESTORE" ]] || { echo "备份文件不存在: $RESTORE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -d "$SCRIPT_DIR/../subscribe" ]] || { echo "找不到 $SCRIPT_DIR/../subscribe，请把整个仓库拷到 VPS" >&2; exit 1; }
CONF_DIR=/etc/sing-box
PA_DIR=/etc/proxy-accelerator

HY2_PH_PORT="${HY2_PH_PORT:-443}";   VLESS_PH_PORT="${VLESS_PH_PORT:-443}"
HY2_HK_PORT="${HY2_HK_PORT:-8443}";  VLESS_HK_PORT="${VLESS_HK_PORT:-8443}"
HOP_PORTS="${HOP_PORTS:-20000-30000}"
UP_MBPS="${UP_MBPS:-50}";            DOWN_MBPS="${DOWN_MBPS:-50}"
WG_PORT="${WG_PORT:-51820}"
# SSH 端口：优先环境变量，其次 sshd_config 里的 Port，否则 22。填错会把自己锁在外面。
SSH_PORT="${SSH_PORT:-$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)}"
SSH_PORT="${SSH_PORT:-22}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
SNI="${SNI:-www.bing.com}"
DOMAIN="${DOMAIN:-}";                EMAIL="${EMAIL:-}"
SUB_DOMAIN_ARG="${SUB_DOMAIN:-}"
TG_BOT_TOKEN_ARG="${TG_BOT_TOKEN:-}";  TG_CHAT_ID_ARG="${TG_CHAT_ID:-}";  BACKUP_TO_TELEGRAM_ARG="${BACKUP_TO_TELEGRAM:-}"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.14.3}"
ADMIN_USER="${ADMIN_USER:-admin}"
TAILSCALE="${TAILSCALE:-0}"
SSH_VIA_TAILSCALE_ARG="${SSH_VIA_TAILSCALE:-}"
RELAY_IMAGE_ARG="${RELAY_IMAGE:-}"
GOPROXY_ARG="${GOPROXY:-}"

echo "==> 安装依赖"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl wireguard-tools nftables ca-certificates \
  fail2ban unattended-upgrades >/dev/null
if [[ "$TAILSCALE" == "1" ]] && ! command -v tailscale >/dev/null 2>&1; then
  echo "==> 安装 Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "==> 安装 Docker"
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
docker compose version >/dev/null 2>&1 || { echo "缺少 docker compose 插件" >&2; exit 1; }

mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
if (( mem_mb < 2048 )) && [[ ! -f /swapfile ]]; then
  echo "==> 内存 ${mem_mb}MB，创建 2G swap 供编译"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> 内核参数（BBR；rp_filter 宽松模式，否则 wg0 的回包会被丢）"
cat > /etc/sysctl.d/99-proxy-accelerator.conf <<SYS
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYS
sysctl -q -p /etc/sysctl.d/99-proxy-accelerator.conf || echo "!! 部分内核参数不支持（通常是 bbr，WSL/定制内核常见），不影响功能，继续"

mkdir -p "$CONF_DIR" "$PA_DIR"
chmod 700 "$PA_DIR"

if [[ -n "$RESTORE" ]]; then
  echo "==> 从备份恢复 relay.env + subscribe.db ($RESTORE)"
  tar -xzf "$RESTORE" -C "$PA_DIR" relay.env subscribe.db
  chmod 600 "$PA_DIR/relay.env"
fi
if [[ -f "$PA_DIR/relay.env" ]]; then
  echo "==> 复用已有密钥 ($PA_DIR/relay.env)"
  # shellcheck disable=SC1091
  source "$PA_DIR/relay.env"
fi
SUB_DOMAIN="${SUB_DOMAIN_ARG:-${SUB_DOMAIN:-}}"
SSH_VIA_TAILSCALE="${SSH_VIA_TAILSCALE_ARG:-${SSH_VIA_TAILSCALE:-0}}"
TG_BOT_TOKEN="${TG_BOT_TOKEN_ARG:-${TG_BOT_TOKEN:-}}"
TG_CHAT_ID="${TG_CHAT_ID_ARG:-${TG_CHAT_ID:-}}"
BACKUP_TO_TELEGRAM="${BACKUP_TO_TELEGRAM_ARG:-${BACKUP_TO_TELEGRAM:-0}}"
RELAY_IMAGE="${RELAY_IMAGE_ARG:-${RELAY_IMAGE:-}}"
GOPROXY="${GOPROXY_ARG:-${GOPROXY:-https://proxy.golang.org,direct}}"
IMG="${RELAY_IMAGE:-proxy-accelerator/relay:$SING_BOX_VERSION}"

printf 'SING_BOX_VERSION=%s\nSUB_DOMAIN=%s\nTG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\nBACKUP_TO_TELEGRAM=%s\nRELAY_IMAGE=%s\nGOPROXY=%s\n' \
  "$SING_BOX_VERSION" "$SUB_DOMAIN" "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$BACKUP_TO_TELEGRAM" "$RELAY_IMAGE" "$GOPROXY" > "$SCRIPT_DIR/.env"
chmod 600 "$SCRIPT_DIR/.env"
if [[ -n "$RELAY_IMAGE" ]]; then
  echo "==> 拉取现成镜像 $RELAY_IMAGE（CI 构建）"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" pull relay
else
  echo "==> 构建 relay 镜像（sing-box $SING_BOX_VERSION + 订阅服务，首次 5–10 分钟；Go 代理 $GOPROXY）"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" build relay
fi
sb() { docker run --rm -v "$CONF_DIR:$CONF_DIR" --entrypoint sing-box "$IMG" "$@"; }

echo "==> 公网地址"
PUBLIC_IP="$(curl -4fsS -m 10 https://api.ipify.org || curl -4fsS -m 10 https://ifconfig.me)"
[[ -n "$PUBLIC_IP" ]] || { echo "拿不到公网 IPv4" >&2; exit 1; }
HOST="${DOMAIN:-$PUBLIC_IP}"

if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
  echo "==> 生成密钥"
  KEYPAIR="$(sb generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk '/PrivateKey/{print $2}' <<<"$KEYPAIR")"
  REALITY_PUBLIC_KEY="$(awk '/PublicKey/{print $2}' <<<"$KEYPAIR")"
  SHORT_ID="$(openssl rand -hex 8)"
  RELAY_WG_PRIVATE_KEY="$(wg genkey)"
  RELAY_WG_PUBLIC_KEY="$(wg pubkey <<<"$RELAY_WG_PRIVATE_KEY")"
  NODE_WG_PRIVATE_KEY="$(wg genkey)"
  NODE_WG_PUBLIC_KEY="$(wg pubkey <<<"$NODE_WG_PRIVATE_KEY")"
  WG_PSK="$(wg genpsk)"
fi

echo "==> 证书"
if [[ -n "$DOMAIN" ]]; then
  INSECURE=0; SNI="$DOMAIN"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/dev/null
  if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    # HTTP-01 需要 80/tcp：首次运行还没装防火墙；重跑时 /etc/nftables.conf 已放行 80
    certbot certonly --standalone -n --agree-tos -m "${EMAIL:-admin@$DOMAIN}" -d "$DOMAIN"
  fi
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/sing-box.sh <<HOOK
#!/bin/sh
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" $CONF_DIR/cert.pem
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" $CONF_DIR/key.pem
docker restart relay >/dev/null 2>&1 || true
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/sing-box.sh
  cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CONF_DIR/cert.pem"
  cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CONF_DIR/key.pem"
else
  INSECURE=1
  if [[ ! -f "$CONF_DIR/cert.pem" ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" -subj "/CN=$SNI" 2>/dev/null
  fi
fi
chmod 600 "$CONF_DIR/key.pem"

echo "==> 写入 relay.env"
cat > "$PA_DIR/relay.env" <<ENV
HOST=$HOST
PUBLIC_IP=$PUBLIC_IP
DOMAIN=$DOMAIN
SUB_DOMAIN=$SUB_DOMAIN
SSH_VIA_TAILSCALE=$SSH_VIA_TAILSCALE
TG_BOT_TOKEN=$TG_BOT_TOKEN
TG_CHAT_ID=$TG_CHAT_ID
BACKUP_TO_TELEGRAM=$BACKUP_TO_TELEGRAM
HY2_PH_PORT=$HY2_PH_PORT
VLESS_PH_PORT=$VLESS_PH_PORT
HY2_HK_PORT=$HY2_HK_PORT
VLESS_HK_PORT=$VLESS_HK_PORT
HOP_PORTS=$HOP_PORTS
UP_MBPS=$UP_MBPS
DOWN_MBPS=$DOWN_MBPS
WG_PORT=$WG_PORT
SSH_PORT=$SSH_PORT
SNI=$SNI
INSECURE=$INSECURE
REALITY_SNI=$REALITY_SNI
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID
RELAY_WG_PRIVATE_KEY=$RELAY_WG_PRIVATE_KEY
RELAY_WG_PUBLIC_KEY=$RELAY_WG_PUBLIC_KEY
NODE_WG_PRIVATE_KEY=$NODE_WG_PRIVATE_KEY
NODE_WG_PUBLIC_KEY=$NODE_WG_PUBLIC_KEY
WG_PSK=$WG_PSK
SING_BOX_VERSION=$SING_BOX_VERSION
RELAY_IMAGE=$RELAY_IMAGE
GOPROXY=$GOPROXY
RELAY_DIR=$SCRIPT_DIR
ENV
chmod 600 "$PA_DIR/relay.env"

echo "==> 渲染 sing-box 配置"
if [[ ! -f "$CONF_DIR/config.json" ]]; then
  sed -e "s|__HY2_PH_PORT__|$HY2_PH_PORT|g"     -e "s|__VLESS_PH_PORT__|$VLESS_PH_PORT|g" \
      -e "s|__HY2_HK_PORT__|$HY2_HK_PORT|g"     -e "s|__VLESS_HK_PORT__|$VLESS_HK_PORT|g" \
      -e "s|__UP_MBPS__|$UP_MBPS|g"             -e "s|__DOWN_MBPS__|$DOWN_MBPS|g" \
      -e "s|__SNI__|$SNI|g"                     -e "s|__REALITY_SNI__|$REALITY_SNI|g" \
      -e "s|__REALITY_PRIVATE_KEY__|$REALITY_PRIVATE_KEY|g" -e "s|__SHORT_ID__|$SHORT_ID|g" \
      "$SCRIPT_DIR/sing-box/config.template.json" > "$CONF_DIR/config.json"
else
  echo "    已存在 $CONF_DIR/config.json，保留用户列表不覆盖"
fi
sb check -c "$CONF_DIR/config.json"

echo "==> WireGuard 服务端"
mkdir -p /etc/wireguard
sed -e "s|__WG_PORT__|$WG_PORT|" -e "s|__RELAY_PRIVATE_KEY__|$RELAY_WG_PRIVATE_KEY|" \
    -e "s|__NODE_PUBLIC_KEY__|$NODE_WG_PUBLIC_KEY|" -e "s|__PSK__|$WG_PSK|" \
    "$SCRIPT_DIR/wg0.conf.template" > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
systemctl enable -q wg-quick@wg0
systemctl restart wg-quick@wg0

cat > "$PA_DIR/ph-node-wg0.conf" <<WG
[Interface]
Address = 10.9.0.2/24
PrivateKey = $NODE_WG_PRIVATE_KEY
MTU = 1420

[Peer]
# relay $HOST
PublicKey = $RELAY_WG_PUBLIC_KEY
PresharedKey = $WG_PSK
Endpoint = ${DOMAIN:-$PUBLIC_IP}:$WG_PORT
AllowedIPs = 10.9.0.1/32
PersistentKeepalive = 25
WG
chmod 600 "$PA_DIR/ph-node-wg0.conf"

echo "==> SSH 加固"
if [[ "$SSH_VIA_TAILSCALE" == "1" ]]; then
  # 只有 Tailscale 真的在线才敢关公网 SSH，否则会把自己锁在外面
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && ip link show tailscale0 >/dev/null 2>&1; then
    SSH_RULE="iifname \"tailscale0\" tcp dport $SSH_PORT accept"
    echo "    公网 SSH 关闭，仅允许 Tailscale（$(tailscale ip -4 2>/dev/null | head -1)）"
  else
    echo "!! SSH_VIA_TAILSCALE=1 但 Tailscale 未登录/未连通，本次仍保留公网 SSH。先 tailscale up --ssh 再重跑" >&2
    SSH_VIA_TAILSCALE=0
    SSH_RULE="tcp dport $SSH_PORT accept"
  fi
else
  SSH_RULE="tcp dport $SSH_PORT accept"
fi
if [[ -s /root/.ssh/authorized_keys ]]; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-proxy-accelerator.conf <<SSHD
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
SSHD
  sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  echo "    已关闭密码登录（root 已有 authorized_keys）"
else
  echo "!! /root/.ssh/authorized_keys 为空，保留密码登录；建议配好密钥后重跑以关闭密码登录"
fi
cat > /etc/fail2ban/jail.d/sshd.local <<F2B
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
F2B
systemctl enable -q fail2ban && systemctl restart fail2ban

echo "==> 自动安全更新（unattended-upgrades，只装 Debian/Ubuntu 安全源，不自动重启）"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable -q unattended-upgrades 2>/dev/null || true

echo "==> 防火墙 nftables"
sed -e "s|__SSH_RULE__|$SSH_RULE|g" -e "s|__WG_PORT__|$WG_PORT|g" -e "s|__HOP_PORTS__|$HOP_PORTS|g" \
    -e "s|__HY2_PH_PORT__|$HY2_PH_PORT|g" -e "s|__VLESS_PH_PORT__|$VLESS_PH_PORT|g" \
    -e "s|__HY2_HK_PORT__|$HY2_HK_PORT|g" -e "s|__VLESS_HK_PORT__|$VLESS_HK_PORT|g" \
    "$SCRIPT_DIR/nftables.conf.template" > /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable -q nftables
nft -f /etc/nftables.conf

echo "==> 启动 relay + caddy"
(cd "$SCRIPT_DIR" && docker compose up -d)
cat > /usr/local/bin/pa <<PA
#!/bin/sh
# 宿主机上的 pa 命令：转发到 relay 容器
exec docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T relay pa "\$@"
PA
chmod +x /usr/local/bin/pa
for _ in $(seq 1 30); do
  curl -fsS -m 2 http://127.0.0.1:8000/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS -m 2 http://127.0.0.1:8000/healthz >/dev/null || { echo "订阅服务没起来："; docker logs --tail 50 relay; exit 1; }

echo "==> 节点与首个用户 [$ADMIN_USER]"
pa nodes sync-env
pa list | grep -q "^$ADMIN_USER " || pa adduser "$ADMIN_USER" --note "管理员"
ADMIN_URL="$(pa url "$ADMIN_USER")"

cat <<EOF

======================================================================
部署完成。
  公网地址:      $HOST  (IP $PUBLIC_IP)
  用户入口:      hy2/udp $HY2_PH_PORT (+跳跃 $HOP_PORTS)、reality/tcp $VLESS_PH_PORT → 宿舍出口
                 hy2/udp $HY2_HK_PORT、reality/tcp $VLESS_HK_PORT → 本机直出
  订阅服务:      https://$PUBLIC_IP:2053（Caddy，自签）$( [[ -n "$SUB_DOMAIN" ]] && echo "→ 经 Cloudflare: https://$SUB_DOMAIN" )
  WireGuard:     udp $WG_PORT，等待宿舍节点接入
  用户管理:      pa adduser <name> [--quota 100G] [--days 30] | pa list | pa url <name> | pa disable <name> | pa --help
  [$ADMIN_USER] 订阅: $ADMIN_URL
  手动导出配置:  pa clash $ADMIN_USER --out /root/$ADMIN_USER.yaml   （没有订阅域名时用这个导入 Clash Verge）
  告警:          $( [[ -n "$TG_BOT_TOKEN" ]] && echo "Telegram 已配置，pa alert test 发测试消息" || echo "未配置（TG_BOT_TOKEN= TG_CHAT_ID= 重跑 install.sh）" )
  SSH:           $( [[ "$SSH_VIA_TAILSCALE" == "1" ]] && echo "仅 Tailscale" || echo "公网 $SSH_PORT/tcp + fail2ban（装好 Tailscale 后 SSH_VIA_TAILSCALE=1 重跑可关公网）" )
  备份:          每天 04:00 → $PA_DIR/backups/（保留 14 份）；pa backup 手动；新 VPS 用 install.sh --restore <文件> 重建

下一步：把下面这个文件拷到宿舍笔记本，运行 node-ph/install.sh
  $PA_DIR/ph-node-wg0.conf
----------------------------------------------------------------------
$(cat "$PA_DIR/ph-node-wg0.conf")
----------------------------------------------------------------------
Cloudflare（有订阅域名时）：sub.<domain> A 记录指向 $PUBLIC_IP 并开启代理（橙云）；
  SSL/TLS 模式 = Full；Rules → Origin Rules 新建：主机名等于 sub.<domain> → 目标端口改写为 2053
验证（宿舍节点接入后）：
  wg show                                   # latest handshake 应在 2 分钟内
  curl --interface wg0 -4 -s https://ip.sb  # 应显示宿舍的菲律宾 IP
  docker logs -f relay
======================================================================
EOF
