# relay · 入口中转 VPS

Debian 12 / Ubuntu 22.04+，root。把**整个仓库**拷到 VPS（例如 `/opt/proxy-accelerator`），`install.sh` 需要同级的 `subscribe/`。

```bash
# 最简：自签证书，客户端 skip-cert-verify
UP_MBPS=40 DOWN_MBPS=40 bash relay/install.sh

# 有域名：relay.<domain> A 记录指到本机（灰云）做 Hysteria2 证书；sub.<domain> 橙云做订阅
DOMAIN=relay.example.com EMAIL=me@example.com SUB_DOMAIN=sub.example.com UP_MBPS=40 DOWN_MBPS=40 bash relay/install.sh
```

`UP_MBPS/DOWN_MBPS` 填宿舍晚高峰实测上行 × 0.8，填高了 Hysteria2 会把链路打爆。

**镜像从哪来**：默认在 VPS 上编译 sing-box（5–10 分钟，需要能顺畅访问 proxy.golang.org）。推荐直接用 CI 构建好的镜像 `ghcr.io/codefans/proxy-accelerator-relay:1.14.3`（每次 main 分支推送后 CI 自动构建并推送，公开可匿名拉取；升级 sing-box 时改 ci.yml 与 Dockerfile 里的版本号，CI 会推出新标签）：

```bash
RELAY_IMAGE=ghcr.io/codefans/proxy-accelerator-relay:1.14.3 UP_MBPS=40 DOWN_MBPS=40 bash relay/install.sh
```

本机编译但 Go 下载慢：`GOPROXY=https://goproxy.io,direct bash relay/install.sh`。

装完会打印 `/etc/proxy-accelerator/ph-node-wg0.conf`（拷到宿舍笔记本给 `node-ph/install.sh`）和管理员的订阅地址。

## 日常：`pa` 命令

```bash
pa adduser alice --quota 100G --days 30   # 新用户，打印订阅地址，60 秒内（通常立刻）生效
pa url alice                              # 订阅地址
pa clash alice --out /root/alice.yaml     # 导出 Clash YAML（没有订阅域名时手动导入）
pa list                                   # 状态 / 已用流量 / 到期
pa stats [alice]                          # 本月与近 7 天流量
pa renew alice --days 30                  # 续期（从 max(今天, 到期日) 起算）
pa quota alice 50G                        # 改月配额，0 = 不限
pa disable alice | pa enable alice
pa reset-token alice                      # 订阅地址泄露时换一个
pa reset-usage alice                      # 本月流量清零
pa del alice
pa nodes list | pa nodes disable HK-中转 | pa nodes sync-env   # 节点表；换 VPS 重跑 install.sh 后自动 sync-env
pa nodes add-standby <备机IP>             # 备用中转（relay-standby/）
pa nodes add-v6 ph.example.com            # 宿舍 IPv6 直连节点（node-ph/v6/），排在所有线路最前
pa sync                                   # 立即同步到 sing-box（正常不需要）
```

运维：

```bash
wg show                                   # 宿舍节点握手
curl --interface wg0 -4 -s https://ip.sb  # 经宿舍出口的 IP
docker logs -f relay                      # sing-box + 订阅服务日志
curl -s 127.0.0.1:8000/healthz            # {"status":"ok","singbox":true}
```

## 订阅域名（Cloudflare）

TCP 443 被 Reality 占用，订阅服务由 Caddy 在 **2053** 提供（自签证书）。Cloudflare 侧：

1. `sub.<domain>` A 记录 → VPS IP，开启代理（橙云）
2. SSL/TLS → 模式 **Full**（不是 Full strict）
3. Rules → Origin Rules → 新建：主机名等于 `sub.<domain>` → Destination port 改写为 `2053`

之后用户访问 `https://sub.<domain>/sub/<token>` 不用带端口；VPS 换 IP 只改 A 记录。没有域名时用 `pa clash` 导出 YAML 手动导入。

## 告警与备份（M3）

**Telegram 告警**：在 Telegram 找 @BotFather 建一个 bot 拿到 token；给 bot 发一条消息后打开 `https://api.telegram.org/bot<token>/getUpdates` 找到自己的 `chat.id`。然后：

```bash
TG_BOT_TOKEN=123456:ABC... TG_CHAT_ID=987654 bash relay/install.sh   # 其余参数自动沿用 relay.env
pa alert test
```

每 60 秒检查：WireGuard 握手（超 3 分钟算断）、经隧道访问外网、中转自身访问外网、sing-box 进程。连续 2 次失败发"🔴 故障"，恢复发"✅ 已恢复（中断 N 分钟）"。单用户 24 小时流量超 20 GB 发一次提醒（`PA_TRAFFIC_WARN_GB` 可调）。

**备份**：每天 04:00（北京时间）把 `relay.env` + `subscribe.db` 打成 tar.gz 放到 `/etc/proxy-accelerator/backups/`，保留 14 份。`pa backup` 手动做一份。加 `BACKUP_TO_TELEGRAM=1` 重跑 install.sh 后每日备份也会发到 Telegram（文件含密钥与用户 token，只发到自己的私聊）。

**换 VPS / 重建**（30 分钟内）：

```bash
# 新 VPS 上，拷好仓库和一份备份文件
DOMAIN=relay.example.com SUB_DOMAIN=sub.example.com bash relay/install.sh --restore /root/pa-backup-20261101-0400.tar.gz
```

密钥、用户、节点全部沿用，用户订阅地址不变。然后把 `relay.<domain>` 和 `sub.<domain>` 的 DNS 指到新 IP。宿舍节点的 WireGuard Endpoint 用的是域名，watchdog 发现握手断了会重启 wg 重新解析，自动接上，不用碰笔记本。没用域名的话要把新打印的 `ph-node-wg0.conf` 拷到笔记本重跑 `node-ph/install.sh`。

## 安全（install.sh 默认就做）

- **fail2ban** 盯 sshd（5 次失败封 1 小时，systemd 日志后端，Debian 12 没有 auth.log 也能用）
- **unattended-upgrades** 只装发行版安全源，不自动重启；Docker 来自 Docker 自己的源不受影响
- root 已有 `authorized_keys` 时自动关闭密码登录；没有则保留并提示
- **关掉公网 SSH**（可选，推荐）：先 `TAILSCALE=1 bash relay/install.sh` 装好并 `tailscale up --ssh` 登录，从 Tailscale 网络 SSH 进来确认能连，再 `SSH_VIA_TAILSCALE=1 bash relay/install.sh`。脚本会检查 Tailscale 确实在线才会收紧，否则保留公网并提示。宿舍笔记本和你的电脑都装 Tailscale 后，两台机器之间也能直接 SSH。

## 改参数

重跑 `install.sh` 会复用 `relay.env` 里的密钥并保留 `config.json`。拿到 M0 实测后要改 Hysteria2 带宽：

```bash
jq '(.inbounds[] | select(.type=="hysteria2") | .up_mbps) = 40 | (.inbounds[] | select(.type=="hysteria2") | .down_mbps) = 40' /etc/sing-box/config.json > /tmp/c.json && mv /tmp/c.json /etc/sing-box/config.json
sed -i 's/^UP_MBPS=.*/UP_MBPS=40/; s/^DOWN_MBPS=.*/DOWN_MBPS=40/' /etc/proxy-accelerator/relay.env
pa nodes sync-env && docker restart relay
```

## 文件

| 路径 | 内容 |
|---|---|
| `/etc/proxy-accelerator/relay.env` | 全部密钥与参数（600 权限） |
| `/etc/proxy-accelerator/subscribe.db` | 用户 / 节点 / 流量（SQLite） |
| `/etc/sing-box/config.json` | 运行配置，`users[]` 由订阅服务维护，不要手改用户 |
| `/etc/wireguard/wg0.conf` | WireGuard 服务端 |
| `/etc/nftables.conf` | 防火墙 |

**备份这两个就能在新 VPS 上重建**：`relay.env` + `subscribe.db`。放回 `/etc/proxy-accelerator/` 再跑 `install.sh`，用户不用改订阅。

## 结构

`relay` 容器里 Python 进程是父进程：拉起 sing-box 子进程并看护，每 60 秒从 sing-box 的 v2ray_api 拉各用户流量、累加、算出有效用户（启用、未到期、未超额）、写回 `config.json` 的 `users[]`，有变化才 `sing-box check` 并重启子进程。4 个入站：`hy2-ph`/`vless-ph`（443）→ 出站 `ph-out`（绑定 wg0，经宿舍）；`hy2-hk`/`vless-hk`（8443）→ 出站 `direct`（本机直出）。
