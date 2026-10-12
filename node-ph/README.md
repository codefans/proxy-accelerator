# node-ph · 宿舍出口节点

旧笔记本，Debian 12 最小安装，**接网线**。先在中转跑完 `relay/install.sh`，把它打印的 `ph-node-wg0.conf` 拷过来。

```bash
# 把 node-ph/ 目录和 ph-node-wg0.conf 拷到笔记本后：
sudo RATE_MBIT=40 RATE_MBIT_PEAK=25 bash install.sh ./ph-node-wg0.conf
# RATE_MBIT = 平时限速（宿舍实测上行 × 0.65）；RATE_MBIT_PEAK = 20–23 点晚高峰；夜间 23–08 点默认不限；0 = 不限速
# 想顺便装 Tailscale 远程管理：TAILSCALE=1 ...，装完手动 tailscale up --ssh
```

节点上没有 sing-box，只有三样东西：

| 组件 | 作用 | 看状态 |
|---|---|---|
| `wg-quick@wg0` | 主动连到中转，keepalive 25s 穿 CGNAT | `wg show` |
| nftables `pa_filter` / `pa_nat` | wg0 → 宿舍网卡 NAT；封 25/tcp 和 BT 端口 | `nft list ruleset` |
| `pa-watchdog.timer` | 每分钟：隧道断了重启 wg0；没网重启网络；10 分钟没网重启机器；停电放电到 5%（`BATTERY_MIN`）正常关机 | `journalctl -t pa-watchdog -f` |
| `unattended-upgrades` | 只装安全更新，不自动重启 | `journalctl -u unattended-upgrades` |
| `pa-tc.sh` | 按时段出口限速（平时 / 晚高峰 / 夜间），watchdog 每分钟调用，速率没变不动 qdisc | `tc qdisc show dev <网卡>`、`journalctl -t pa-tc` |

改参数：编辑 `/etc/proxy-accelerator/node.env`，一分钟内自动生效。
故障告警不在这台机上做：中转侧的订阅服务直接看 WireGuard 握手和经隧道的出网探测，断了发 Telegram。

手动要做：BIOS 开来电自启；笔记本合盖不休眠已由脚本配置。

## IPv6 直连线路（可选，`v6/`）

宿舍有公网 IPv6 时，本机再跑一个 sing-box 监听 IPv6，国内有 IPv6 的用户（手机流量基本都有）直连，少一跳、不占中转流量；没 IPv6 的用户和故障时仍走中转。Clash 的 fallback 组把它排在最前，连不上自动跳过。

```bash
# 先确认 WireGuard 已通（wg show 有握手），然后：
sudo V6_HOST=ph.example.com CF_API_TOKEN=<Zone.DNS:Edit 的 token> CF_ZONE=example.com bash v6/install-v6.sh
# 中转上：
pa nodes add-v6 ph.example.com
```

- Reality 密钥、short_id、端口、有效用户列表都经 WireGuard 每分钟从中转 `GET /internal/node` 拉取（watchdog 调 `pa-sync-v6.sh`），用户变化一分钟内生效，到期/停用的用户同样被踢
- DDNS：本机稳定的全局 IPv6 变了就更新 Cloudflare 的 AAAA（灰云，TTL 120）；不给 token 就自己维护 AAAA
- 防火墙 `/etc/nftables.d/v6.nft`：IPv6 公网只放 sing-box 端口，其余（含 SSH）丢弃
- **限制**：走这条线的流量不经中转，**不计入用户配额**，月配额只管中转流量；宿舍出口总限速（tc）仍然生效
- 验证：国内用户用手机流量在 Clash 里手动选 `PH-直连 IPv6 hy2`。不通先查宿舍路由器有没有放 IPv6 入站（很多光猫/路由器默认拦），`journalctl -t pa-v6 -f` 看同步与 DDNS

验证（在中转上）：`curl --interface wg0 -4 -s https://ip.sb` 显示本机的菲律宾 IP。
