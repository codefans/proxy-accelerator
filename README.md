# proxy-accelerator · 宿舍家宽代理加速器

以菲律宾宿舍 WiFi 为出口、Clash Verge 订阅为交付形态的小规模跨境代理，亲友自用。

```
国内用户 Clash Verge ──hy2/reality──▶ 入口中转 VPS (JP/HK) ──WireGuard──▶ 宿舍笔记本 ──NAT──▶ 互联网（菲律宾住宅 IP）
                                      │ 订阅服务 + 流量统计 + 告警 + 备份              看门狗 / 限速 / 封 SMTP·BT
                                      └─ 自身出口（宿舍断线时的兜底线路）
          （可选）备用中转 VPS ──端口转发──▶ 主中转     主 IP 被封时 Clash 自动切换
```

- 产品方案 [docs/PRD.md](docs/PRD.md) · 技术架构 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · 落地路线 [docs/ROADMAP.md](docs/ROADMAP.md)
- VPS 选型 [docs/VPS-OPTIONS.md](docs/VPS-OPTIONS.md) · 网络探测结果 [docs/PROBE-RESULT.md](docs/PROBE-RESULT.md)
- 发给用户的说明 [docs/USER-GUIDE.md](docs/USER-GUIDE.md)

## 目录

```
scripts/probe-network.sh   宿舍网络探测（M0）
relay/                     主中转：install.sh · Dockerfile(自编译 sing-box + 订阅服务) · compose · Caddy · doctor.sh
relay-standby/             备用中转：nftables 端口转发到主中转
node-ph/                   宿舍节点：install.sh · WireGuard · NAT · 分时段限速 · watchdog · doctor.sh · v6/（IPv6 直连线路）
subscribe/                 订阅服务源码（FastAPI + SQLite）与测试：用户/节点/流量/告警/备份/pa 命令
docs/
```

## 部署顺序

1. 宿舍笔记本（Debian 12）跑 `sudo bash scripts/probe-network.sh`，四个时段，结果填 `docs/PROBE-RESULT.md`，定出 `UP_MBPS`
2. 整个仓库拷到 VPS：`UP_MBPS=40 DOWN_MBPS=40 SUB_DOMAIN=sub.<domain> bash relay/install.sh`（详见 [relay/README.md](relay/README.md)）
3. 把它打印的 `ph-node-wg0.conf` 拷到笔记本：`sudo RATE_MBIT=40 bash node-ph/install.sh ph-node-wg0.conf`（详见 [node-ph/README.md](node-ph/README.md)）
4. 中转上 `bash relay/doctor.sh`，"经宿舍出口"一栏显示菲律宾 IP 即打通
5. `pa adduser <name> --quota 100G --days 30`，把订阅地址和 `docs/USER-GUIDE.md` 发给用户

## 运维速查

| 要做什么 | 在哪 | 命令 |
|---|---|---|
| 加人 / 踢人 / 续期 / 改配额 | 中转 | `pa adduser x --quota 100G --days 30` · `pa disable x` · `pa renew x --days 30` · `pa quota x 50G` |
| 看谁在用多少流量 | 中转 | `pa list` · `pa stats` |
| 订阅地址泄露 | 中转 | `pa reset-token x` |
| 体检 / 排障 | 中转、宿舍 | `bash relay/doctor.sh` · `bash node-ph/doctor.sh`（把输出贴回来） |
| 告警 | 中转 | `TG_BOT_TOKEN=… TG_CHAT_ID=… bash relay/install.sh`，`pa alert test` |
| 备份 | 中转 | 每天 04:00 自动到 `/etc/proxy-accelerator/backups/`；`pa backup --telegram` |
| 换 VPS / 主 IP 被封 | 新 VPS | `bash relay/install.sh --restore <备份.tar.gz>`，改 DNS；用户无感 |
| 加备用中转 | 备机 + 中转 | `PRIMARY=<主IP> bash relay-standby/install.sh`，然后 `pa nodes add-standby <备机IP>` |
| 开 IPv6 直连线路 | 宿舍 + 中转 | `V6_HOST=ph.<domain> CF_API_TOKEN=… CF_ZONE=<domain> bash node-ph/v6/install-v6.sh`，然后 `pa nodes add-v6 ph.<domain>` |
| 改 Hysteria2 带宽 | 中转 | 见 relay/README「改参数」 |
| 改宿舍限速 | 宿舍 | 编辑 `/etc/proxy-accelerator/node.env`，一分钟生效 |
| 升级 sing-box | 中转 | `SING_BOX_VERSION=1.x.y bash relay/install.sh` |

## 开发

```bash
cd subscribe && pip install -r requirements-dev.txt && pytest -q    # 不需要 sing-box / grpcio
```

当前状态：M0–M4 代码完成，40 个单元测试；**尚未在真实 VPS 与笔记本上验证**。
