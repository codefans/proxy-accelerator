#!/usr/bin/env bash
# 宿舍节点一键体检。出问题时整段输出贴回来即可定位。root 运行。
set -u
# shellcheck disable=SC1091
source /etc/proxy-accelerator/node.env 2>/dev/null || { echo "没有 /etc/proxy-accelerator/node.env，还没跑 install.sh？"; exit 1; }
sec() { echo; echo "===== $* ====="; }

sec "系统"
echo "$(hostname)  $(uname -r)  $(uptime -p)"
free -m | awk 'NR<=2'
[[ -d /sys/class/power_supply/BAT0 ]] && echo "电池: $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)%  $(cat /sys/class/power_supply/BAT0/status 2>/dev/null)"

sec "网络接入（出口网卡 $WAN_IF）"
ip -4 addr show "$WAN_IF" | awk '/inet /{print "IPv4:", $2}'
ip -6 addr show "$WAN_IF" scope global | awk '/inet6/{print "IPv6:", $2}'
[[ -d "/sys/class/net/$WAN_IF/wireless" ]] && echo "!! 走的是 WiFi，建议接网线"
echo "默认网关: $(ip route | awk '/^default/{print $3; exit}')"
curl -4 -s -m 10 https://ipinfo.io/json 2>/dev/null | tr -d '\n' | grep -oE '"(ip|org|city)": *"[^"]*"' | tr '\n' ' '
echo

sec "WireGuard"
wg show 2>&1
last="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -n "${last:-}" && "$last" != 0 ]]; then echo "上次握手: $(( $(date +%s) - last )) 秒前"; else echo "!! 从未握手"; fi
if ping -c 2 -W 3 "${RELAY_WG_IP:-10.9.0.1}" >/dev/null 2>&1; then echo "ping 中转 ${RELAY_WG_IP:-10.9.0.1}: 通"; else echo "!! ping 中转不通"; fi
echo "Endpoint: $(grep -E '^Endpoint' /etc/wireguard/wg0.conf | awk '{print $3}')"

sec "转发与 NAT"
echo "ip_forward=$(sysctl -n net.ipv4.ip_forward)  rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter)"
nft list table ip pa_nat 2>&1 | grep -E 'masquerade|error' || echo "!! pa_nat 表不存在"
nft list table inet pa_filter 2>&1 | grep -cE 'drop|accept' | sed 's/^/pa_filter 规则数: /'

sec "限速（当前小时 $(date +%H)）"
tc qdisc show dev "$WAN_IF" 2>&1
echo "配置: 平时 ${RATE_MBIT:-?} / 高峰 ${RATE_MBIT_PEAK:-?}(${PEAK_HOURS:-}) / 夜间 ${RATE_MBIT_NIGHT:-?}(${NIGHT_HOURS:-})  当前应用: $(cat /run/pa-tc.rate 2>/dev/null || echo 未知)"

sec "watchdog 最近记录"
systemctl is-active pa-watchdog.timer | sed 's/^/timer: /'
journalctl -t pa-watchdog -t pa-tc --no-pager -n 10 2>/dev/null || true

if [[ -n "${V6_HOST:-}" ]]; then
  sec "IPv6 直连线路 ($V6_HOST)"
  systemctl is-active sing-box | sed 's/^/sing-box: /'
  ss -lntup 2>/dev/null | awk '/sing-box/{print $1, $5}' | sort -u
  echo "DDNS 上次写入: $(cat /run/pa-v6/last_addr 2>/dev/null || echo 无)   解析: $(getent ahostsv6 "$V6_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
  echo "有效用户: $(jq -r '[.inbounds[0].users[].name] | join(",")' /etc/sing-box/config.json 2>/dev/null)"
  journalctl -t pa-v6 --no-pager -n 5 2>/dev/null || true
fi

sec "电源/合盖"
grep -E 'HandleLidSwitch' /etc/systemd/logind.conf.d/lid.conf 2>/dev/null | tr '\n' ' '
echo
