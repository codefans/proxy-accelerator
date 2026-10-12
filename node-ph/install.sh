#!/usr/bin/env bash
# 宿舍出口节点一键部署：WireGuard 反连中转 + NAT 出口 + 出口限速 + watchdog
# 适用：Debian 12 / Ubuntu 22.04+，root 运行。可重复运行。
#
# 用法：
#   sudo bash install.sh /path/to/ph-node-wg0.conf          # 文件来自中转 install.sh 的输出
# 可选环境变量：
#   WAN_IF=eth0            出口网卡，默认自动探测（优先有线）
#   RATE_MBIT=40           平时出口限速 Mbit，填宿舍实测上行 × 0.65；0 = 不限
#   RATE_MBIT_PEAK=25      晚高峰 PEAK_HOURS=20-23 的限速（给宿舍同学留带宽），缺省 = RATE_MBIT
#   RATE_MBIT_NIGHT=0      夜间 NIGHT_HOURS=23-08 的限速，缺省 0 = 不限
#   TAILSCALE=1            同时安装 Tailscale（装完需要手动 tailscale up --ssh 登录一次）
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请以 root 运行" >&2; exit 1; }
WG_CONF="${1:?用法: install.sh <ph-node-wg0.conf>}"
[[ -f "$WG_CONF" ]] || { echo "文件不存在: $WG_CONF" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PA_DIR=/etc/proxy-accelerator
RATE_MBIT="${RATE_MBIT:-40}"
RATE_MBIT_PEAK="${RATE_MBIT_PEAK:-$RATE_MBIT}"
RATE_MBIT_NIGHT="${RATE_MBIT_NIGHT:-0}"
PEAK_HOURS="${PEAK_HOURS:-20-23}"
NIGHT_HOURS="${NIGHT_HOURS:-23-08}"
TAILSCALE="${TAILSCALE:-0}"

echo "==> 安装依赖"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools nftables iproute2 curl ca-certificates \
  unattended-upgrades >/dev/null

echo "==> 自动安全更新（只装安全源，不自动重启）"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable -q unattended-upgrades 2>/dev/null || true

WAN_IF="${WAN_IF:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)}"
[[ -n "$WAN_IF" ]] || { echo "探测不到出口网卡，请用 WAN_IF=xxx 指定" >&2; exit 1; }
if [[ -d "/sys/class/net/$WAN_IF/wireless" ]]; then
  echo "!! 出口网卡 $WAN_IF 是 WiFi，长期运行请改接网线"
fi
echo "    出口网卡: $WAN_IF   限速: ${RATE_MBIT} Mbit"

echo "==> WireGuard"
mkdir -p /etc/wireguard
install -m 600 "$WG_CONF" /etc/wireguard/wg0.conf

echo "==> 内核参数（转发）"
cat > /etc/sysctl.d/99-proxy-accelerator.conf <<SYS
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYS
sysctl -q -p /etc/sysctl.d/99-proxy-accelerator.conf || echo "!! 部分内核参数不支持（通常是 bbr），不影响功能，继续"

echo "==> nftables（NAT + 封 SMTP/BT）"
mkdir -p /etc/nftables.d
[[ -e /etc/nftables.d/00-placeholder.nft ]] || echo '# proxy-accelerator 附加规则目录（v6.nft 等）' > /etc/nftables.d/00-placeholder.nft
sed -e "s|__WAN_IF__|$WAN_IF|g" "$SCRIPT_DIR/nftables.conf.template" > /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable -q nftables
nft -f /etc/nftables.conf

echo "==> 节点参数与限速"
mkdir -p "$PA_DIR"
cat > "$PA_DIR/node.env" <<ENV
WAN_IF=$WAN_IF
RATE_MBIT=$RATE_MBIT
RATE_MBIT_PEAK=$RATE_MBIT_PEAK
RATE_MBIT_NIGHT=$RATE_MBIT_NIGHT
PEAK_HOURS=$PEAK_HOURS
NIGHT_HOURS=$NIGHT_HOURS
RELAY_WG_IP=10.9.0.1
BATTERY_MIN=5
ENV
install -m 755 "$SCRIPT_DIR/pa-tc.sh" /usr/local/sbin/pa-tc.sh
install -m 644 "$SCRIPT_DIR/pa-tc.service" /etc/systemd/system/pa-tc.service

echo "==> watchdog"
install -m 755 "$SCRIPT_DIR/watchdog.sh" /usr/local/sbin/pa-watchdog.sh
install -m 644 "$SCRIPT_DIR/pa-watchdog.service" /etc/systemd/system/pa-watchdog.service
install -m 644 "$SCRIPT_DIR/pa-watchdog.timer" /etc/systemd/system/pa-watchdog.timer

echo "==> 笔记本：合盖不休眠"
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' > /etc/systemd/logind.conf.d/lid.conf
systemctl kill -s HUP systemd-logind 2>/dev/null || true

systemctl daemon-reload
systemctl enable -q wg-quick@wg0 pa-tc.service pa-watchdog.timer
systemctl restart wg-quick@wg0
systemctl restart pa-tc.service
systemctl start pa-watchdog.timer

if [[ "$TAILSCALE" == "1" ]] && ! command -v tailscale >/dev/null 2>&1; then
  echo "==> 安装 Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi

echo "==> 验证"
sleep 3
wg show wg0
if ping -c 3 -W 3 10.9.0.1 >/dev/null 2>&1; then
  echo "    隧道通：ping 10.9.0.1 OK"
else
  echo "!! ping 10.9.0.1 不通。检查：中转 wg0 是否已启动、Endpoint 是否正确、udp 51820 是否放行；watchdog 每分钟会自动重试"
fi

cat <<EOF

======================================================================
宿舍节点部署完成。
  出口网卡 $WAN_IF，限速 平时 ${RATE_MBIT} / 晚高峰(${PEAK_HOURS}时) ${RATE_MBIT_PEAK} / 夜间(${NIGHT_HOURS}时) ${RATE_MBIT_NIGHT} Mbit，0=不限
  （改 $PA_DIR/node.env，watchdog 每分钟自动应用；journalctl -t pa-tc 看切换记录）
  watchdog 每分钟检查隧道与网络：journalctl -t pa-watchdog -f
  参数文件: $PA_DIR/node.env

还需要你手动做的：
  1. BIOS 里打开 "AC Power Recovery / Restore on AC Power Loss"（来电自启）
  2. 如果装了 Tailscale：tailscale up --ssh   然后在浏览器完成登录
  3. 在中转上验证：curl --interface wg0 -4 -s https://ip.sb  应显示本机的菲律宾 IP
======================================================================
EOF
