#!/usr/bin/env bash
# 本地（Linux / WSL）一键检查，等价于 .github/workflows/ci.yml 的前两个 job：
#   脚本静态检查 → 四份 nftables 规则 nft -c → sing-box 配置 check → IPv6 节点 jq 渲染 → Python 测试（含 grpcio）
# 用法：bash scripts/check-local.sh        需要 sudo（nft -c 要 CAP_NET_ADMIN）
set -euo pipefail
export LC_ALL=C.UTF-8   # 静态检查工具读含中文的注释需要 UTF-8 locale
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SB_VER="${SING_BOX_VERSION:-1.14.3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok() { printf '\033[32m✔ %s\033[0m\n' "$*"; }

echo "==> 依赖"
need=()
for p in shellcheck nftables jq curl openssl python3-venv; do dpkg -s "$p" >/dev/null 2>&1 || need+=("$p"); done
((${#need[@]})) && sudo apt-get install -y -qq "${need[@]}" >/dev/null
ok "依赖齐全"

echo "==> shellcheck"
# shellcheck disable=SC2046
shellcheck -S warning $(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './subscribe/.venv/*') subscribe/pa
ok "shellcheck 无警告"

echo "==> nftables 规则语法（真实 nft -c）"
sudo mkdir -p /etc/nftables.d
sed -e 's|__WAN_IF__|eth0|g' -e 's|__HY2_PORT__|443|g' -e 's|__VLESS_PORT__|443|g' -e 's|__HOP_PORTS__|20000-30000|g' \
    node-ph/v6/nftables-v6.conf.template | sudo tee /etc/nftables.d/v6.nft >/dev/null
render_relay() {
  sed -e "s|__SSH_RULE__|$1|" -e 's|__WG_PORT__|51820|g' -e 's|__HOP_PORTS__|20000-30000|g' \
      -e 's|__HY2_PH_PORT__|443|g' -e 's|__VLESS_PH_PORT__|443|g' -e 's|__HY2_HK_PORT__|8443|g' -e 's|__VLESS_HK_PORT__|8443|g' \
      relay/nftables.conf.template
}
render_relay 'tcp dport 22 accept' > "$TMP/relay.nft";                        sudo nft -c -f "$TMP/relay.nft"
render_relay 'iifname "tailscale0" tcp dport 22 accept' > "$TMP/relay-ts.nft"; sudo nft -c -f "$TMP/relay-ts.nft"
sed -e 's|__WAN_IF__|eth0|g' node-ph/nftables.conf.template > "$TMP/node.nft";  sudo nft -c -f "$TMP/node.nft"
sed -n '/^cat > \/etc\/nftables.conf <<NFT$/,/^NFT$/p' relay-standby/install.sh | sed '1d;$d' \
  | sed -e 's|\$SSH_PORT|22|g' -e 's|\$WAN_IF|eth0|g' -e 's|\$TCP_PORTS|443,8443|g' -e 's|\$UDP_PORTS|443,8443|g' \
        -e 's|\$HOP_PORTS|20000-30000|g' -e 's|\$PRIMARY_IP|203.0.113.1|g' > "$TMP/standby.nft"
sudo nft -c -f "$TMP/standby.nft"
ok "relay / relay(tailscale) / node(+v6) / standby 四份规则语法正确"

echo "==> sing-box $SB_VER 配置校验（官方构建，去掉 v2ray_api 段）"
SB="$TMP/sing-box"
curl -fsSL -o "$TMP/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz"
tar xzf "$TMP/sb.tgz" -C "$TMP" && mv "$TMP/sing-box-${SB_VER}-linux-amd64/sing-box" "$SB"
openssl ecparam -genkey -name prime256v1 -out "$TMP/key.pem" 2>/dev/null
openssl req -new -x509 -days 1 -key "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
PRIV="$("$SB" generate reality-keypair | awk '/PrivateKey/{print $2}')"
sed -e 's|__HY2_PH_PORT__|443|g' -e 's|__VLESS_PH_PORT__|443|g' -e 's|__HY2_HK_PORT__|8443|g' -e 's|__VLESS_HK_PORT__|8443|g' \
    -e 's|__UP_MBPS__|50|g' -e 's|__DOWN_MBPS__|50|g' -e 's|__SNI__|www.bing.com|g' -e 's|__REALITY_SNI__|www.microsoft.com|g' \
    -e "s|__REALITY_PRIVATE_KEY__|$PRIV|g" -e 's|__SHORT_ID__|0123456789abcdef|g' -e "s|/etc/sing-box/|$TMP/|g" \
    relay/sing-box/config.template.json | jq 'del(.experimental.v2ray_api)' > "$TMP/relay.json"
"$SB" check -c "$TMP/relay.json"
ok "中转 sing-box 模板合法"
jq -n --arg priv "$PRIV" '{version:1, params:{REALITY_PRIVATE_KEY:$priv, SHORT_ID:"0123456789abcdef", REALITY_SNI:"www.microsoft.com", SNI:"www.bing.com", HY2_PH_PORT:"443", VLESS_PH_PORT:"443", HOP_PORTS:"20000-30000", UP_MBPS:"40", DOWN_MBPS:"40"}, users:[{name:"b",uuid:"11111111-2222-3333-4444-555555555555",hy2_password:"pw"},{name:"a",uuid:"22222222-2222-3333-4444-555555555555",hy2_password:"pw2"}], v6_host:"ph.example.com"}' > "$TMP/node.json"
jq -f node-ph/v6/render.jq --arg cert "$TMP/cert.pem" --arg key "$TMP/key.pem" "$TMP/node.json" > "$TMP/v6.json"
"$SB" check -c "$TMP/v6.json"
ok "IPv6 节点配置（jq 渲染）合法"

echo "==> 限速脚本时段逻辑（干跑）"
printf 'WAN_IF=eth0\nRATE_MBIT=40\nRATE_MBIT_PEAK=25\nRATE_MBIT_NIGHT=0\nPEAK_HOURS=20-23\nNIGHT_HOURS=23-08\n' > "$TMP/node.env"
for h in 08 12 20 22 23 00 07; do
  rm -f "$TMP/state"
  r="$(PA_NODE_ENV="$TMP/node.env" PA_TC_STATE="$TMP/state" PA_TC_DRYRUN=1 bash node-ph/pa-tc.sh apply "$h" | grep -oE 'rate [0-9]+mbit|qdisc del' || true)"
  printf '  %s时 → %s\n' "$h" "${r:-?}"
done
ok "限速干跑完成（期望 08/12→40，20/22→25，23/00/07→del）"

echo "==> Python 测试（含 grpcio 等完整依赖）"
cd subscribe
[[ -d .venv ]] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements-dev.txt
.venv/bin/python -m pytest -q
ok "pytest 通过"

echo
echo "全部通过。Docker 镜像由 CI 构建（ghcr.io/codefans/proxy-accelerator-relay），VPS 上部署："
echo "  RELAY_IMAGE=ghcr.io/codefans/proxy-accelerator-relay:1.14.3 UP_MBPS=40 DOWN_MBPS=40 bash relay/install.sh"
