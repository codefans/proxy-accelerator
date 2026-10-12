#!/usr/bin/env bash
# 中转一键体检。出问题时整段输出贴回来即可定位。root 运行。
set -u
PA_DIR=/etc/proxy-accelerator
# shellcheck disable=SC1091
source "$PA_DIR/relay.env" 2>/dev/null || { echo "没有 $PA_DIR/relay.env，还没跑 install.sh？"; exit 1; }
sec() { echo; echo "===== $* ====="; }
RELAY_DIR="${RELAY_DIR:-$(cd "$(dirname "$0")" && pwd)}"

sec "系统"
echo "$(hostname)  $(uname -r)  $(uptime -p)"
free -m | awk 'NR<=2'
df -h / | tail -1
echo "swap: $(swapon --show --noheadings | awk '{print $1, $3}' | tr '\n' ' ')"

sec "容器"
docker compose -f "$RELAY_DIR/docker-compose.yml" ps 2>&1

sec "订阅服务 /healthz"
curl -s -m 3 http://127.0.0.1:8000/healthz || echo "(不可达)"
echo

sec "relay 最近日志（告警/错误）"
docker logs --tail 200 relay 2>&1 | grep -E 'ERROR|WARNING|故障|恢复|重启|失败' | tail -15 || true

sec "WireGuard"
wg show 2>&1
last="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -n "${last:-}" && "$last" != 0 ]]; then echo "上次握手: $(( $(date +%s) - last )) 秒前"; else echo "!! 从未握手：宿舍节点没接上"; fi

sec "经宿舍出口（应为菲律宾住宅 IP）"
curl --interface wg0 -4 -s -m 10 https://ipinfo.io/json 2>/dev/null | tr -d '\n' | grep -oE '"(ip|org|city|country)": *"[^"]*"' | tr '\n' ' ' || echo "!! 经 wg0 出不去"
echo

sec "本机出口"
curl -4 -s -m 10 https://ipinfo.io/json 2>/dev/null | tr -d '\n' | grep -oE '"(ip|org|country)": *"[^"]*"' | tr '\n' ' '
echo

sec "监听端口（期望：$HY2_PH_PORT/$HY2_HK_PORT udp，$VLESS_PH_PORT/$VLESS_HK_PORT tcp，2053 tcp，$WG_PORT udp，8000 与 10085 仅本机）"
ss -lntup 2>/dev/null | awk 'NR==1 || /:(443|8443|2053|51820|8000|10085)[[:space:]]/' | awk '{print $1, $5, $7}' | sort -u

sec "nftables（input 与 nat）"
nft list chain inet filter input 2>&1 | grep -vE '^\s*$' | head -20
nft list table ip nat 2>&1 | head -12

sec "用户"
pa list 2>&1
echo "有效用户写入 sing-box: $(jq -r '.experimental.v2ray_api.stats.users | join(",")' /etc/sing-box/config.json 2>/dev/null)"

sec "流量统计是否在工作（最近 200 行日志里拉取失败的次数，应为 0 或极少）"
echo "$(docker logs --tail 200 relay 2>&1 | grep -c '拉取流量统计失败') 次"

sec "备份"
ls -la "$PA_DIR/backups" 2>/dev/null | tail -4 || echo "(还没有备份)"

sec "参数"
grep -E '^(HOST|DOMAIN|SUB_DOMAIN|UP_MBPS|DOWN_MBPS|INSECURE|SING_BOX_VERSION)=' "$PA_DIR/relay.env"
echo "Telegram: $([[ -n "${TG_BOT_TOKEN:-}" ]] && echo 已配置 || echo 未配置)"
