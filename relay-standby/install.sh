#!/usr/bin/env bash
# 备用中转：纯端口转发（nftables DNAT）到主中转，无状态、无用户数据。
# 主中转 IP 被封时，订阅里的"·备"节点仍可用，Clash fallback 组自动切过去。
# 适用：Debian 12 / Ubuntu 22.04+，root。换一家不同 ASN 的便宜 VPS 即可。
#
# 用法：PRIMARY=<主中转公网IP或域名> bash install.sh
# 可选：TCP_PORTS="443,8443" UDP_PORTS="443,8443" HOP_PORTS=20000-30000 SSH_PORT=<自动探测>
# 装完在主中转上执行：pa nodes add-standby <本机公网IP>
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "请以 root 运行" >&2; exit 1; }
PRIMARY="${PRIMARY:?用法: PRIMARY=<主中转IP> bash install.sh}"
TCP_PORTS="${TCP_PORTS:-443,8443}"
UDP_PORTS="${UDP_PORTS:-443,8443}"
HOP_PORTS="${HOP_PORTS:-20000-30000}"
SSH_PORT="${SSH_PORT:-$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)}"
SSH_PORT="${SSH_PORT:-22}"

echo "==> 安装依赖"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables curl ca-certificates >/dev/null

# nft 的 dnat 需要 IP；传的是域名就解析一次
if [[ ! "$PRIMARY" =~ ^[0-9.]+$ ]]; then
  PRIMARY_IP="$(getent ahostsv4 "$PRIMARY" | awk 'NR==1{print $1}')"
  [[ -n "$PRIMARY_IP" ]] || { echo "解析不了 $PRIMARY" >&2; exit 1; }
else
  PRIMARY_IP="$PRIMARY"
fi
WAN_IF="$(ip route get "$PRIMARY_IP" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"

echo "==> 内核参数"
cat > /etc/sysctl.d/99-proxy-accelerator.conf <<SYS
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYS
sysctl -q -p /etc/sysctl.d/99-proxy-accelerator.conf || echo "!! 部分内核参数不支持（通常是 bbr），不影响功能，继续"

echo "==> nftables：转发 tcp {$TCP_PORTS} udp {$UDP_PORTS} udp $HOP_PORTS → $PRIMARY_IP"
cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif "lo" accept
    icmp type echo-request accept
    icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-router-solicit } accept
    tcp dport $SSH_PORT accept comment "SSH"
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ct status dnat accept comment "转发到主中转的连接"
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100;
    iifname "$WAN_IF" tcp dport { $TCP_PORTS } dnat to $PRIMARY_IP
    iifname "$WAN_IF" udp dport { $UDP_PORTS } dnat to $PRIMARY_IP
    iifname "$WAN_IF" udp dport $HOP_PORTS dnat to $PRIMARY_IP
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    ip daddr $PRIMARY_IP masquerade
  }
}
NFT
nft -c -f /etc/nftables.conf
systemctl enable -q nftables
nft -f /etc/nftables.conf

PUBLIC_IP="$(curl -4fsS -m 10 https://api.ipify.org || curl -4fsS -m 10 https://ifconfig.me)"
cat <<EOF

======================================================================
备用中转部署完成：$PUBLIC_IP → $PRIMARY_IP（tcp $TCP_PORTS / udp $UDP_PORTS / udp $HOP_PORTS）
在主中转上执行，把备机加进所有用户的订阅：
  pa nodes add-standby $PUBLIC_IP
验证（任一已有用户的 Clash 里把节点手动切到 "PH-宿舍·备 hy2"，能上网即通）。
本机状态：nft list ruleset；conntrack -L 2>/dev/null | head
======================================================================
EOF
