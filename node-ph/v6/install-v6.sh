#!/usr/bin/env bash
# IPv6 直连线路（宿舍侧）：本机跑 sing-box 监听公网 IPv6，国内有 IPv6 的用户直连，不经中转。
# 前提：已跑过 node-ph/install.sh 且 WireGuard 通（用户列表和 Reality 密钥都经隧道从中转拉）；
#       宿舍有公网 IPv6 且路由器允许入站（没把握先装，装完让国内用户测）。
#
# 用法：sudo V6_HOST=ph.example.com CF_API_TOKEN=xxx CF_ZONE=example.com bash install-v6.sh
#   V6_HOST        这台机器的 AAAA 域名（Cloudflare 灰云），订阅里的 PH-直连 节点就是它
#   CF_API_TOKEN   Cloudflare API Token，权限 Zone.DNS:Edit（只给这个 zone）；不填则不做 DDNS，自己维护 AAAA
#   CF_ZONE        根域名，如 example.com
# 中转侧：pa nodes add-v6 ph.example.com
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请以 root 运行" >&2; exit 1; }
V6_HOST="${V6_HOST:?用法: V6_HOST=ph.example.com [CF_API_TOKEN=.. CF_ZONE=..] bash install-v6.sh}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE="${CF_ZONE:-}"
RELAY_API="${RELAY_API:-http://10.9.0.1:8000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PA_DIR=/etc/proxy-accelerator
[[ -f "$PA_DIR/node.env" ]] || { echo "先跑 node-ph/install.sh" >&2; exit 1; }
# shellcheck disable=SC1091
source "$PA_DIR/node.env"

echo "==> 依赖"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq curl openssl ca-certificates >/dev/null
if ! command -v sing-box >/dev/null 2>&1; then
  echo "==> 安装 sing-box（官方 deb 源）"
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi
sing-box version | head -1

echo "==> 从中转拉取参数（经 WireGuard $RELAY_API）"
json="$(curl -fsS -m 10 "$RELAY_API/internal/node")" || {
  echo "!! 拉不到 $RELAY_API/internal/node。检查：wg show 是否握手；中转是否已更新到含 /internal/node 的版本（docker logs relay）" >&2; exit 1; }
HY2_PORT="$(jq -r '.params.HY2_PH_PORT' <<<"$json")"
VLESS_PORT="$(jq -r '.params.VLESS_PH_PORT' <<<"$json")"
HOP_PORTS="$(jq -r '.params.HOP_PORTS' <<<"$json")"
SNI="$(jq -r '.params.SNI' <<<"$json")"
[[ "$HY2_PORT" =~ ^[0-9]+$ && "$VLESS_PORT" =~ ^[0-9]+$ ]] || { echo "中转返回的端口不合法: $json" >&2; exit 1; }
echo "    hy2 udp $HY2_PORT (+$HOP_PORTS)  reality tcp $VLESS_PORT  用户 $(jq -r '.users|length' <<<"$json") 个"

echo "==> 证书（自签，客户端 skip-cert-verify）"
mkdir -p /etc/sing-box "$PA_DIR/v6"
if [[ ! -f /etc/sing-box/cert.pem ]]; then
  openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/key.pem 2>/dev/null
  openssl req -new -x509 -days 3650 -key /etc/sing-box/key.pem -out /etc/sing-box/cert.pem -subj "/CN=$SNI" 2>/dev/null
  chmod 600 /etc/sing-box/key.pem
fi

echo "==> 同步脚本与参数"
install -m 644 "$SCRIPT_DIR/render.jq" "$PA_DIR/v6/render.jq"
install -m 755 "$SCRIPT_DIR/sync-v6.sh" /usr/local/sbin/pa-sync-v6.sh
sed -i '/^\(V6_HOST\|CF_API_TOKEN\|CF_ZONE\|RELAY_API\)=/d' "$PA_DIR/node.env"
cat >> "$PA_DIR/node.env" <<ENV
V6_HOST=$V6_HOST
CF_API_TOKEN=$CF_API_TOKEN
CF_ZONE=$CF_ZONE
RELAY_API=$RELAY_API
ENV
chmod 600 "$PA_DIR/node.env"

echo "==> nftables：IPv6 公网只放 sing-box 端口"
mkdir -p /etc/nftables.d
sed -e "s|__WAN_IF__|$WAN_IF|g" -e "s|__HY2_PORT__|$HY2_PORT|g" -e "s|__VLESS_PORT__|$VLESS_PORT|g" \
    -e "s|__HOP_PORTS__|$HOP_PORTS|g" "$SCRIPT_DIR/nftables-v6.conf.template" > /etc/nftables.d/v6.nft
grep -q 'nftables.d' /etc/nftables.conf || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf

echo "==> 首次渲染并启动 sing-box"
systemctl enable -q sing-box
/usr/local/sbin/pa-sync-v6.sh
sleep 1
systemctl is-active sing-box >/dev/null || { journalctl -u sing-box -n 30 --no-pager; exit 1; }

addr="$(ip -6 addr show dev "$WAN_IF" scope global -temporary 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)"
cat <<EOF

======================================================================
IPv6 直连线路已启动。
  本机全局 IPv6: ${addr:-（没有！这条线路起不来）}
  监听: hy2 udp $HY2_PORT (+$HOP_PORTS)、reality tcp $VLESS_PORT，仅 IPv6 公网可达
  DDNS: $( [[ -n "$CF_API_TOKEN" ]] && echo "$V6_HOST → 当前地址，每分钟检查" || echo "未配置，请手动把 $V6_HOST 的 AAAA 指到上面的地址" )
  用户同步: 每分钟经 WireGuard 从中转拉，日志 journalctl -t pa-v6 -f

下一步：
  1. 中转上执行:  pa nodes add-v6 $V6_HOST
  2. 让国内用户（手机流量，有 IPv6）在 Clash 里手动选 "PH-直连 IPv6 hy2" 测试；不通先查宿舍路由器的 IPv6 防火墙/入站放行
  3. 本机自检:  ss -lntup | grep -E ':($HY2_PORT|$VLESS_PORT) '   nft list table inet pa_v6
======================================================================
EOF
