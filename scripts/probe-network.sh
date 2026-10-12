#!/usr/bin/env bash
# 宿舍网络探测（ROADMAP M0）。在宿舍那台笔记本上跑，Debian 12 / Ubuntu 22.04+（Live USB 也行）。
#
# 用法：
#   sudo bash probe-network.sh                      # 一次完整探测，约 3–5 分钟
#   sudo TARGETS="1.2.3.4 5.6.7.8" bash probe-network.sh   # 额外对候选 VPS IP 做 mtr（买了 VPS 后用）
#   sudo QUICK=1 bash probe-network.sh              # 跳过测速，只看 IP / NAT / IPv6 / 延迟
#
# 每次运行写一个 probe-<时间>.txt，并追加到 probe-log.md。
# 建议一天跑 4 次：10:00 / 15:00 / 21:00 / 23:00，跑完把 probe-log.md 发回来。
set -u

OUT_DIR="${OUT_DIR:-$HOME/probe}"
TARGETS="${TARGETS:-}"
QUICK="${QUICK:-0}"
STAMP="$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/probe-$STAMP.txt"
LOG="$OUT_DIR/probe-log.md"

# ---------- 工具 ----------
say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
hr()   { say ""; say "== $* =="; }
have() { command -v "$1" >/dev/null 2>&1; }
# 兼容 speedtest-cli（apt）与 Ookla speedtest（官方二进制）
SPEEDTEST=""
if have speedtest-cli; then SPEEDTEST="speedtest-cli"; elif have speedtest; then SPEEDTEST="speedtest"; fi

ensure_tools() {
  local need=()
  have curl       || need+=(curl)
  have mtr        || need+=(mtr-tiny)
  have traceroute || need+=(traceroute)
  have jq         || need+=(jq)
  have ethtool    || need+=(ethtool)
  have iw         || need+=(iw)
  [[ -n "$SPEEDTEST" ]] || need+=(speedtest-cli)
  if ((${#need[@]})); then
    if [[ $EUID -eq 0 ]] && have apt-get; then
      say "安装缺失工具: ${need[*]}"
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq "${need[@]}" >/dev/null 2>&1 || say "!! 有工具安装失败，相关项会跳过"
      have speedtest-cli && SPEEDTEST="speedtest-cli"
    else
      say "!! 缺少工具: ${need[*]}（用 sudo 运行可自动安装）"
    fi
  fi
}

# 摘要变量（最后汇总用）
S_IFACE="?" S_LINK="?" S_PUB4="无" S_ISP="?" S_NAT="?" S_V6="无"
S_LOCAL="跳过" S_HK="跳过" S_JP="跳过" S_LOSS=""

# ---------- 0. 基本信息 ----------
basic_info() {
  hr "基本信息"
  say "时间:   $(date '+%F %T %Z')"
  say "主机:   $(hostname)  内核: $(uname -r)"
  local route iface gw src
  route="$(ip route get 1.1.1.1 2>/dev/null | head -1)"
  iface="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$route")"
  gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$route")"
  src="$(awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' <<<"$route")"
  S_IFACE="${iface:-?}"
  say "出口网卡: ${iface:-?}   本机IP: ${src:-?}   网关: ${gw:-?}"
  if [[ -n "${iface:-}" ]]; then
    if [[ -d "/sys/class/net/$iface/wireless" ]]; then
      S_LINK="WiFi"
      have iw && say "WiFi:   $(iw dev "$iface" link 2>/dev/null | grep -E 'SSID|freq|signal|bitrate' | tr -s ' \t' ' ' | tr '\n' ';')"
    else
      S_LINK="有线"
      have ethtool && say "有线:   $(ethtool "$iface" 2>/dev/null | grep -E 'Speed|Duplex' | tr -s ' \t' ' ' | tr '\n' ' ')"
    fi
  fi
  say "DNS:    $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  say "链路类型: $S_LINK（方案要求长期用有线）"
}

# ---------- 1. 公网 IPv4 与 ISP ----------
public_v4() {
  hr "公网 IPv4"
  local info ip org
  info="$(curl -4 -fsS --max-time 10 https://ipinfo.io/json 2>/dev/null || true)"
  if [[ -n "$info" ]] && have jq; then
    ip="$(jq -r '.ip // empty' <<<"$info")"
    org="$(jq -r '.org // empty' <<<"$info")"
    say "出口 IPv4: ${ip:-?}   ISP/ASN: ${org:-?}   城市: $(jq -r '.city // "?"' <<<"$info")"
  else
    ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    say "出口 IPv4: ${ip:-获取失败}"
  fi
  S_PUB4="${ip:-无}"; S_ISP="${org:-?}"
  # 住宅 vs 机房的粗判
  if [[ -n "${org:-}" ]] && grep -qiE 'PLDT|Globe|Converge|Smart|Sky|DITO|Eastern' <<<"$org"; then
    say "判断:     住宅/本地 ISP（符合预期）"
  elif [[ -n "${org:-}" ]]; then
    say "判断:     ISP 名称不像菲律宾住宅宽带，确认一下是否校园网/企业线路: $org"
  fi
}

# ---------- 2. NAT 层数（CGNAT 推断） ----------
nat_layers() {
  hr "NAT 层数推断（traceroute 前 8 跳）"
  local hops n=0 priv=0 first_pub=""
  hops="$(traceroute -n -m 8 -w 2 -q 1 1.1.1.1 2>/dev/null | tail -n +2 || true)"
  [[ -z "$hops" ]] && { say "traceroute 失败，跳过"; return; }
  say "$hops"
  while read -r line; do
    local ip; ip="$(awk '{print $2}' <<<"$line")"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    n=$((n+1))
    if [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
      priv=$((priv+1))
    elif [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
      priv=$((priv+1)); say "  第 $n 跳 $ip 属于 100.64.0.0/10 → 运营商 CGNAT"
    else
      [[ -z "$first_pub" ]] && first_pub="$ip"
    fi
  done <<<"$hops"
  S_NAT="$priv"
  say "到第一个公网地址($first_pub)之前有 $priv 个私网/CGNAT 跳"
  case "$priv" in
    0) say "判断:     本机直接拿到公网 IP（罕见，很好）" ;;
    1) say "判断:     只有宿舍路由器一层 NAT，宿舍路由器 WAN 口可能是公网 IP → 登录路由器看 WAN IP 是否等于上面的出口 IPv4；相等则有公网 IPv4，可考虑端口映射" ;;
    *) say "判断:     ≥2 层 NAT（宿舍路由 + 楼宇/运营商），基本确定没有公网 IPv4，按方案走中转 + WireGuard 反连" ;;
  esac
}

# ---------- 3. IPv6 ----------
ipv6_check() {
  hr "IPv6"
  local addrs ip6
  addrs="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2, ($0 ~ /temporary/ ? "(临时)" : ($0 ~ /mngtmpaddr|dynamic/ ? "(SLAAC)" : ""))}')"
  if [[ -z "$addrs" ]]; then say "本机没有全局 IPv6 地址"; S_V6="无"; return; fi
  say "本机全局 IPv6:"; say "$addrs"
  # 直接用 Cloudflare 的 v6 地址，不依赖 DNS 的 AAAA 解析
  ip6="$(curl -6 -fsS --max-time 10 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null | awk -F= '/^ip=/{print $2}')"
  [[ -z "$ip6" ]] && ip6="$(curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null | grep ':' || true)"
  if [[ -n "$ip6" ]]; then
    say "出口 IPv6: $ip6（出站可用）"
    S_V6="有($ip6)"
    say "注意:     入站是否可达要等有 VPS 后从外面 ping6/nc 验证；路由器可能有 IPv6 防火墙"
  else
    say "有地址但出不去（IPv6 不可用）"; S_V6="有地址不通"
  fi
}

# ---------- 4. 延迟与丢包 ----------
mtr_one() {
  local target="$1" label="$2" line loss avg
  if have mtr; then
    line="$(mtr -rwc 50 -n -4 "$target" 2>/dev/null | tail -1)"
    [[ -z "$line" ]] && { say "$label $target: mtr 失败"; return; }
    loss="$(awk '{print $3}' <<<"$line")"; avg="$(awk '{print $6}' <<<"$line")"
    say "$label $target: 丢包 $loss  平均 ${avg} ms  （50 包）"
  else
    line="$(ping -c 30 -i 0.3 -W 2 "$target" 2>/dev/null | tail -2 | tr '\n' ' ')"
    loss="$(grep -oE '[0-9.]+% packet loss' <<<"$line" | head -1)"
    avg="$(grep -oE 'rtt.*' <<<"$line" | cut -d/ -f5)"
    say "$label $target: 丢包 ${loss:-?}  平均 ${avg:-?} ms  （ping 30 包）"
  fi
  S_LOSS+="$label ${loss:-?}/${avg:-?}ms; "
}
latency() {
  hr "延迟与丢包"
  mtr_one 1.1.1.1 "Cloudflare(anycast)"
  mtr_one 8.8.8.8 "Google(anycast)  "
  for t in $TARGETS; do mtr_one "$t" "候选VPS        "; done
  [[ -z "$TARGETS" ]] && say "(买了 VPS 后用 TARGETS=\"<ip>\" 重跑，补这一项；商家的 looking glass 测试 IP 也可以)"
  if have mtr; then
    hr "到 1.1.1.1 完整路径（看国际出口在哪跳开始丢包）"
    mtr -rwc 20 -n -4 1.1.1.1 2>/dev/null | tee -a "$REPORT" >/dev/null
  fi
}

# ---------- 5. 带宽 ----------
run_speedtest() {   # $1=label  $2=server-id(可空)
  local label="$1" sid="${2:-}" out dl ul ping srv
  if [[ "$SPEEDTEST" == "speedtest-cli" ]]; then
    out="$(timeout 180 speedtest-cli --secure ${sid:+--server "$sid"} 2>/dev/null || true)"
    dl="$(grep -oE 'Download: [0-9.]+ Mbit/s' <<<"$out" | grep -oE '[0-9.]+')"
    ul="$(grep -oE 'Upload: [0-9.]+ Mbit/s'   <<<"$out" | grep -oE '[0-9.]+')"
    ping="$(grep -oE 'Hosted by .*' <<<"$out" | grep -oE '[0-9.]+ ms')"
    srv="$(grep -oE 'Hosted by [^:]+' <<<"$out" | sed 's/Hosted by //')"
  else
    out="$(timeout 180 speedtest --accept-license --accept-gdpr -f json ${sid:+-s "$sid"} 2>/dev/null || true)"
    if [[ -n "$out" ]] && have jq; then
      dl="$(jq -r '(.download.bandwidth*8/1e6*100|round)/100' <<<"$out")"
      ul="$(jq -r '(.upload.bandwidth*8/1e6*100|round)/100' <<<"$out")"
      ping="$(jq -r '(.ping.latency*10|round)/10' <<<"$out") ms"
      srv="$(jq -r '.server.name + " / " + .server.location' <<<"$out")"
    fi
  fi
  if [[ -n "${dl:-}" ]]; then
    say "$label: 下行 ${dl} Mbps  上行 ${ul} Mbps  延迟 ${ping:-?}  服务器: ${srv:-?}"
    printf '%s' "↓${dl}/↑${ul}"
  else
    say "$label: 测速失败（服务器不可用或超时）"
    printf '%s' "失败"
  fi
}
find_server() {   # 按关键词在 speedtest-cli --list 里找一个服务器 id
  [[ "$SPEEDTEST" == "speedtest-cli" ]] || return 0
  speedtest-cli --list 2>/dev/null | grep -iE "$1" | head -1 | grep -oE '^ *[0-9]+' | tr -d ' '
}
bandwidth() {
  hr "带宽（speedtest）"
  [[ "$QUICK" == "1" ]] && { say "QUICK=1，跳过"; return; }
  [[ -z "$SPEEDTEST" ]] && { say "没有 speedtest 工具，跳过"; return; }
  say "注意: 上行是整个方案的瓶颈；晚高峰(21:00–23:00)的数字最重要"
  S_LOCAL="$(run_speedtest "本地最近服务器")"
  local hk jp
  hk="$(find_server 'Hong Kong|HKG')"; jp="$(find_server 'Tokyo|Osaka|Japan')"
  if [[ -n "$hk" ]]; then S_HK="$(run_speedtest "到香港服务器   " "$hk")"; else say "列表里没找到香港服务器，跳过（≈ 宿舍到 HK 中转的带宽）"; fi
  if [[ -n "$jp" ]]; then S_JP="$(run_speedtest "到日本服务器   " "$jp")"; else say "列表里没找到日本服务器，跳过（≈ 宿舍到 JP 中转的带宽）"; fi
}

# ---------- 6. 出站端口是否被宿舍网络封 ----------
egress_ports() {
  hr "出站端口连通性（宿舍网络有没有封常用端口）"
  local p r
  # 1.1.1.1 在这几个 Cloudflare 端口上都有 TCP 监听，适合探测宿舍是否封非 80/443 端口
  for p in 443 8443 2053 2083; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/$p" 2>/dev/null; then r="通"; else r="不通"; fi
    say "TCP $p → 1.1.1.1: $r"
  done
  # UDP 用 DNS 探一下 53；WireGuard(51820/udp)、Hysteria2(443/udp) 没有公共探测目标，留到有 VPS 再测
  if timeout 5 bash -c 'exec 3<>/dev/udp/1.1.1.1/53 && printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03one\x03one\x03one\x03one\x00\x00\x01\x00\x01" >&3 && timeout 3 head -c 1 <&3 >/dev/null' 2>/dev/null; then
    say "UDP 53 → 1.1.1.1: 通（UDP 出站基本正常）"
  else
    say "UDP 53 → 1.1.1.1: 不通或被劫持（注意：若 UDP 被限，WireGuard/Hysteria2 需要换端口测）"
  fi
}

# ---------- 汇总 ----------
summary() {
  hr "摘要（贴回 docs/PROBE-RESULT.md 用）"
  local md
  md="| $(date '+%m-%d %H:%M') | $S_LINK/$S_IFACE | $S_PUB4 ($S_ISP) | NAT≥$S_NAT 层 | $S_V6 | 本地 $S_LOCAL | HK $S_HK | JP $S_JP | $S_LOSS |"
  say "| 时间 | 链路 | 公网IPv4 (ISP) | NAT | IPv6 | 本地带宽 Mbps | 到HK | 到JP | 丢包/延迟 |"
  say "$md"
  {
    [[ -s "$LOG" ]] || printf '# 宿舍网络探测记录\n\n| 时间 | 链路 | 公网IPv4 (ISP) | NAT | IPv6 | 本地带宽 Mbps | 到HK | 到JP | 丢包/延迟 |\n|---|---|---|---|---|---|---|---|---|\n' >> "$LOG"
    printf '%s\n' "$md" >> "$LOG"
  }
  say ""
  say "完整报告: $REPORT"
  say "汇总日志: $LOG  （跑完 4 个时段后把这个文件发回来）"
}

ensure_tools
: > "$REPORT"
basic_info
public_v4
nat_layers
ipv6_check
egress_ports
latency
bandwidth
summary
