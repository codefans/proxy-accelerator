#!/usr/bin/env bash
# 出口限速（tc tbf），按时段取不同速率，幂等：速率没变就不动 qdisc。
# 参数来自 /etc/proxy-accelerator/node.env：
#   WAN_IF            出口网卡
#   RATE_MBIT         平时速率；0 = 不限
#   RATE_MBIT_PEAK    PEAK_HOURS 内的速率（晚高峰给宿舍同学留带宽），缺省 = RATE_MBIT
#   RATE_MBIT_NIGHT   NIGHT_HOURS 内的速率，缺省 = RATE_MBIT；0 = 不限
#   PEAK_HOURS=20-23  NIGHT_HOURS=23-08   小时区间 [起, 止)，支持跨午夜；留空 = 不启用该时段
# 用法：pa-tc.sh apply [小时]   pa-tc.sh stop
# 测试：PA_TC_DRYRUN=1 只打印 tc 命令不执行
set -u
# shellcheck disable=SC1090
source "${PA_NODE_ENV:-/etc/proxy-accelerator/node.env}"
STATE="${PA_TC_STATE:-/run/pa-tc.rate}"

in_window() {  # $1=小时 $2="20-23"；10# 防止 08/09 被当成八进制
  local h=$((10#$1)) s=$((10#${2%-*})) e=$((10#${2#*-}))
  if (( s <= e )); then (( h >= s && h < e )); else (( h >= s || h < e )); fi
}

pick_rate() {
  local h=$((10#${1:-$(date +%H)}))
  if [[ -n "${PEAK_HOURS:-}" ]] && in_window "$h" "$PEAK_HOURS"; then
    echo "${RATE_MBIT_PEAK:-$RATE_MBIT}"
  elif [[ -n "${NIGHT_HOURS:-}" ]] && in_window "$h" "$NIGHT_HOURS"; then
    echo "${RATE_MBIT_NIGHT:-$RATE_MBIT}"
  else
    echo "${RATE_MBIT:-0}"
  fi
}

tc_run() {
  if [[ -n "${PA_TC_DRYRUN:-}" ]]; then echo "tc $*"; else tc "$@"; fi
}

case "${1:-apply}" in
  apply)
    rate="$(pick_rate "${2:-}")"
    [[ -f "$STATE" && "$(cat "$STATE")" == "$rate" ]] && exit 0
    if (( rate > 0 )); then
      tc_run qdisc replace dev "$WAN_IF" root tbf rate "${rate}mbit" burst 64kb latency 400ms
    else
      tc_run qdisc del dev "$WAN_IF" root 2>/dev/null || true
    fi
    echo "$rate" > "$STATE"
    logger -t pa-tc "出口限速 → ${rate} Mbit（0=不限）" 2>/dev/null || true
    ;;
  stop)
    tc_run qdisc del dev "$WAN_IF" root 2>/dev/null || true
    rm -f "$STATE"
    ;;
  *)
    echo "用法: pa-tc.sh apply|stop" >&2; exit 1 ;;
esac
