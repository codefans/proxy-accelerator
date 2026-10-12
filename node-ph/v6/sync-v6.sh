#!/usr/bin/env bash
# IPv6 直连节点同步，由 watchdog 每分钟调用：
#  1) 经 WireGuard 从中转拉 /internal/node（协议参数 + 有效用户），渲染 sing-box 配置，变了才 check + restart
#  2) DDNS：本机稳定的全局 IPv6 变了就更新 Cloudflare 的 AAAA 记录
set -u
# shellcheck disable=SC1091
source /etc/proxy-accelerator/node.env
RELAY_API="${RELAY_API:-http://10.9.0.1:8000}"
CONF=/etc/sing-box/config.json
RENDER=/etc/proxy-accelerator/v6/render.jq
STATE=/run/pa-v6
mkdir -p "$STATE"
log() { logger -t pa-v6 "$*"; }

# ---- 1. 用户与参数 ----
if json="$(curl -fsS -m 10 "$RELAY_API/internal/node" 2>/dev/null)"; then
  [[ -f "$STATE/pull_failed" ]] && { log "重新连上中转 API"; rm -f "$STATE/pull_failed"; }
  if jq -f "$RENDER" --arg cert /etc/sing-box/cert.pem --arg key /etc/sing-box/key.pem <<<"$json" > "$CONF.new" 2>"$STATE/jq.err"; then
    if ! cmp -s "$CONF.new" "$CONF" 2>/dev/null; then
      if sing-box check -c "$CONF.new" 2>"$STATE/check.err"; then
        mv "$CONF.new" "$CONF"
        systemctl restart sing-box
        log "配置更新（有效用户 $(jq -r '.users | length' <<<"$json") 个），已重启 sing-box"
      else
        log "新配置 check 失败，保留旧配置: $(head -c 200 "$STATE/check.err")"
        rm -f "$CONF.new"
      fi
    else
      rm -f "$CONF.new"
    fi
  else
    log "渲染失败: $(head -c 200 "$STATE/jq.err")"
  fi
else
  [[ -f "$STATE/pull_failed" ]] || { log "拉取 $RELAY_API/internal/node 失败（WireGuard 通吗？）"; touch "$STATE/pull_failed"; }
fi

# ---- 2. DDNS ----
[[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE:-}" && -n "${V6_HOST:-}" ]] || exit 0
addr="$(ip -6 addr show dev "$WAN_IF" scope global -temporary 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)"
if [[ -z "$addr" ]]; then
  [[ -f "$STATE/no_v6" ]] || { log "本机没有全局 IPv6 地址"; touch "$STATE/no_v6"; }
  exit 0
fi
rm -f "$STATE/no_v6"
[[ "$(cat "$STATE/last_addr" 2>/dev/null)" == "$addr" ]] && exit 0

cf() { curl -fsS -m 15 -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
zone="$(cat "$STATE/zone_id" 2>/dev/null || true)"
if [[ -z "$zone" ]]; then
  zone="$(cf "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE" | jq -r '.result[0].id // empty')"
  [[ -n "$zone" ]] && echo "$zone" > "$STATE/zone_id"
fi
[[ -n "$zone" ]] || { log "DDNS: 找不到 zone $CF_ZONE（token 权限？）"; exit 0; }
rec="$(cf "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=AAAA&name=$V6_HOST" | jq -r '.result[0].id // empty')"
body="$(jq -n --arg n "$V6_HOST" --arg a "$addr" '{type:"AAAA", name:$n, content:$a, ttl:120, proxied:false}')"
if [[ -n "$rec" ]]; then
  ok="$(cf -X PUT "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$rec" --data "$body" | jq -r '.success')"
else
  ok="$(cf -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" --data "$body" | jq -r '.success')"
fi
if [[ "$ok" == "true" ]]; then
  echo "$addr" > "$STATE/last_addr"
  log "DDNS: $V6_HOST → $addr"
else
  log "DDNS 更新失败"
fi
