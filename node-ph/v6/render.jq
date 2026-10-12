# 把中转 /internal/node 返回的 JSON 渲染成宿舍侧 sing-box 配置（IPv6 直连线路）。
# 用法：jq -f render.jq --arg cert /etc/sing-box/cert.pem --arg key /etc/sing-box/key.pem node.json
# 与中转共用同一套 Reality 密钥 / short_id / SNI，所以订阅里的 PH-直连 节点只需换 host。
{
  log: { level: "warn", timestamp: true },
  dns: { servers: [ { type: "local", tag: "dns-local" } ] },
  inbounds: [
    {
      type: "hysteria2", tag: "hy2-v6", listen: "::",
      listen_port: (.params.HY2_PH_PORT | tonumber),
      up_mbps: (.params.UP_MBPS | tonumber), down_mbps: (.params.DOWN_MBPS | tonumber),
      users: [ .users | sort_by(.name)[] | { name: .name, password: .hy2_password } ],
      masquerade: "https://www.bing.com",
      tls: { enabled: true, alpn: ["h3"], server_name: .params.SNI, certificate_path: $cert, key_path: $key }
    },
    {
      type: "vless", tag: "vless-v6", listen: "::",
      listen_port: (.params.VLESS_PH_PORT | tonumber),
      users: [ .users | sort_by(.name)[] | { name: .name, uuid: .uuid, flow: "xtls-rprx-vision" } ],
      tls: {
        enabled: true, server_name: .params.REALITY_SNI,
        reality: {
          enabled: true,
          handshake: { server: .params.REALITY_SNI, server_port: 443 },
          private_key: .params.REALITY_PRIVATE_KEY,
          short_id: [ .params.SHORT_ID ]
        }
      }
    }
  ],
  outbounds: [ { type: "direct", tag: "direct", domain_resolver: "dns-local" } ],
  route: { final: "direct", default_domain_resolver: "dns-local" }
}
