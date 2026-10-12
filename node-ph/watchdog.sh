#!/usr/bin/env bash
# 宿舍节点看门狗，由 pa-watchdog.timer 每分钟触发。
#  1) 隧道：握手超过 3 分钟或 ping 不通中转 → 重启 wg0（两次重启间隔 ≥ 2 分钟）
#  2) 网络：网关 ping 不通或访问不了外网，连续 3 次 → 重启网络；连续 10 次 → 重启机器
#  3) 笔记本电池：停电后放电到 BATTERY_MIN%（默认 5）→ 正常关机，避免电池耗尽时损坏文件系统；来电由 BIOS 自启
set -u
# shellcheck disable=SC1091
source /etc/proxy-accelerator/node.env 2>/dev/null || true
RELAY_WG_IP="${RELAY_WG_IP:-10.9.0.1}"
STATE=/run/pa-watchdog
mkdir -p "$STATE"
now="$(date +%s)"
log() { logger -t pa-watchdog "$*"; }
read_n() { cat "$STATE/$1" 2>/dev/null || echo 0; }

# ---- 0. 按时段限速（幂等，速率没变不动 qdisc）----
[[ -x /usr/local/sbin/pa-tc.sh ]] && /usr/local/sbin/pa-tc.sh apply || true

# ---- 0b. 电池 ----
for bat in /sys/class/power_supply/BAT*; do
  [[ -r "$bat/status" && -r "$bat/capacity" ]] || continue
  status="$(cat "$bat/status")"; cap="$(cat "$bat/capacity")"
  if [[ "$status" == "Discharging" ]]; then
    [[ -f "$STATE/on_battery" ]] || { log "外部电源断开，电池 ${cap}%"; touch "$STATE/on_battery"; }
    if (( cap <= ${BATTERY_MIN:-5} )); then
      log "电池 ${cap}% ≤ ${BATTERY_MIN:-5}%，正常关机"
      systemctl poweroff
      exit 0
    fi
  elif [[ -f "$STATE/on_battery" ]]; then
    log "外部电源恢复，电池 ${cap}%"; rm -f "$STATE/on_battery"
  fi
  break
done

# ---- 1. 隧道 ----
last="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
last="${last:-0}"
tunnel_ok=1
if (( now - last > 180 )) || ! ping -c 1 -W 3 "$RELAY_WG_IP" >/dev/null 2>&1; then
  tunnel_ok=0
  if (( now - $(read_n wg_restart) > 120 )); then
    log "隧道异常（握手 $(( now - last ))s 前 / ping 中转失败），重启 wg0"
    systemctl restart wg-quick@wg0
    echo "$now" > "$STATE/wg_restart"
  fi
fi

# ---- 2. 宿舍网络 ----
gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
if [[ -n "$gw" ]] && ping -c 1 -W 2 "$gw" >/dev/null 2>&1 \
   && curl -4fsS -m 8 -o /dev/null https://www.gstatic.com/generate_204; then
  echo 0 > "$STATE/net_fail"
else
  f=$(( $(read_n net_fail) + 1 ))
  echo "$f" > "$STATE/net_fail"
  log "宿舍网络不通，第 $f 次"
  if (( f == 3 )); then
    log "重启网络"
    if command -v nmcli >/dev/null 2>&1; then
      nmcli networking off; sleep 3; nmcli networking on
    else
      systemctl restart networking 2>/dev/null || true
    fi
  elif (( f >= 10 )); then
    log "连续 10 分钟无网，重启机器"
    reboot
  fi
  exit 0
fi

[[ -f "$STATE/tunnel_down" ]] && (( tunnel_ok )) && { log "隧道恢复"; rm -f "$STATE/tunnel_down"; }
(( tunnel_ok )) || touch "$STATE/tunnel_down"

# ---- 4. IPv6 直连线路（装了才有）：拉用户、DDNS ----
[[ -x /usr/local/sbin/pa-sync-v6.sh ]] && /usr/local/sbin/pa-sync-v6.sh || true
