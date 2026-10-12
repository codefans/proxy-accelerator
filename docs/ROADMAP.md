# 落地实施方案（Roadmap）

## 3.1 前置准备（开工前一次性）

| 项 | 说明 |
|---|---|
| 宿舍节点硬件 | 一台旧笔记本（或 N100）+ 一根网线接宿舍路由；U 盘刷 Debian 12 netinst |
| 中转 VPS | 先买月付（JP 软银 / HK 普通线路，$10–20），Debian 12，拿到 root SSH |
| 域名 | 海外注册商购买，NS 指向 Cloudflare；准备 `sub.<domain>`（橙云）与 `relay.<domain>`（灰云） |
| Tailscale 账号 | 免费版即可 |
| 一位国内测试用户 | 能在晚高峰帮你跑 Clash Verge + speedtest 的亲友 |
| 本地开发 | Python 3.12、Docker Desktop（跑 subscribe 的测试）；`git init` 本目录，`docs/` 三份作首个 commit |

## 3.2 里程碑与验证（按周）

### M0 · 宿舍网络探测与决策（W1，必须先做，结论决定后面怎么走）

- 写 `scripts/probe-network.sh`，在宿舍节点上跑，输出：
  - 公网 IPv4：`curl -4 ifconfig.me` 与路由器 WAN 口 IP 是否一致；WAN 是否在 `100.64.0.0/10`（CGNAT）
  - IPv6：`curl -6 ifconfig.co` 是否成功、地址是否全局单播且入站可达（从 VPS `ping6` 回来）
  - 带宽：`speedtest-cli` 分别在 10:00 / 15:00 / 21:00 / 23:00 各跑一次，记录上下行与抖动
  - 到候选 VPS 延迟与丢包：`mtr -rwc 100 <relay>`
  - 国内到候选 VPS：让测试用户跑 `tcping` / 用 itdog.cn 测 `relay.<domain>` 三网延迟
- 确认宿舍/校园网 AUP 是否禁止服务器与带宽转售（文档或问管理员），决定用户规模上限
- **验证 / 决策门**：
  - 上行晚高峰 < 15 Mbps → 项目价值不足，只做"AI 服务专线"（低带宽、住宅 IP），不承诺视频
  - 有公网 IPv6 → 架构加 `PH-直连(IPv6)` 线路（M2 实现）
  - 国内到候选 VPS 晚高峰丢包 > 5% → 换线路再测，不要带着差线路往下做
- 产出：`docs/PROBE-RESULT.md`（数字 + 决策），据此修正 PRD 1.4 带宽预算与 Hysteria2 `up/down`

### M1 · 核心链路打通：手工配置、两个用户（W2）

- `relay/install.sh`：以 `freely-access-to-china-network/server/exit-node/install.sh` 为底改：
  - 自编译 sing-box 镜像（`with_v2ray_api`）；4 个入站（ph/hk × hy2/reality）；`ph-out` 出站 + route 规则
  - kernel wg0 server（`Table = off`）；nftables（放行端口、端口跳跃 redirect）；BBR
  - 脚本末尾打印：宿舍节点的 `wg0.conf`、两个测试用户的 Clash 节点片段
- `node-ph/install.sh`：wireguard + nftables masquerade + ip_forward + tc + watchdog + Tailscale
- 手工拼一份 Clash YAML 给自己和测试用户
- **验证**：
  - 中转：`curl --interface wg0 https://ip.sb` 返回宿舍 PH IP；`wg show` 握手 < 2 min
  - 客户端：`PH-宿舍 hy2` 下 `ip.sb` 显示 PH 住宅 IP 且 ISP 非机房；`HK-中转` 下显示 VPS IP
  - 拔宿舍网线 → Clash `fallback` 组 60 s 内切到 HK；插回 → 3 min 内 PH 恢复（watchdog 日志可见重连）
  - 宿舍节点 `reboot` → 3 min 内 `wg show` 恢复握手，无人工介入
  - 测试用户晚高峰 YouTube 1080P 10 min 不卡；`speedtest` 经 PH 线路的下行 ≥ 宿舍上行实测 × 0.6
  - `grpcurl -plaintext 127.0.0.1:10085 v2ray.core.app.stats.command.StatsService/QueryStats` 能查到 `user>>>…>>>uplink`

### M2 · 订阅服务与用户管理（W3–W4）

- `subscribe/`：
  - `models.py` SQLite 建表 + 迁移（用 `sqlite3` 标准库，不上 ORM）
  - `cli.py`：`adduser <name> [--quota 100G] [--days 30]` / `renew` / `quota` / `disable` / `enable` / `reset-token` / `stats` / `nodes add|list|disable`
  - `render.py` + `templates/clash.yaml.j2`：按 2.6 输出；`subscription-userinfo` 头
  - `main.py`：`GET /sub/<token>`（无效 token 返回 404，不泄露存在性）；`GET /healthz`
  - `sync.py`：进程内 asyncio 循环每 60 s 执行 2.7 的五步；月初归零；sing-box 作为子进程由同一进程看护
  - `tests/`：render 快照（1 用户 × 4 节点）、有效用户判定（到期 / 超额 / 禁用）、sync 的 diff 判断
- `relay/docker-compose.yml`：sing-box（host 网络）+ subscribe + Caddy；`relay/install.sh` 改为一键拉起 compose
- Cloudflare：`sub.<domain>` 橙云 → Caddy；`relay.<domain>` 灰云
- 若 M0 探测到 IPv6：宿舍节点跑 `exit-node` 的 sing-box + Cloudflare DDNS 脚本（复用旁边项目 `server/home-node`），`nodes` 表加 `ph-v6` 节点
- **验证**：
  - `cli.py adduser bob --quota 50G --days 30` → 60 s 内 bob 能连；Clash Verge 订阅页显示流量与到期
  - `cli.py disable bob` → 60 s 内 bob 断连，订阅仍能拉取但无节点
  - 把 bob 配额改成 1 MB → 看一个视频后自动被踢；`stats` 数字与 Clash 显示一致（误差 < 5%）
  - 国内测试用户用手机流量（非 WiFi）拉订阅成功（验证 Cloudflare 可达）
  - `pytest` 全绿；`sing-box check` 通过 sync 渲染的配置

### M3 · 稳定性、运维与用户文档（W5）

- 告警内置在订阅服务（`subscribe/app/alerts.py`，不用 Uptime Kuma）：每 60 秒检查 wg 握手、经隧道出网、中转出网、sing-box 存活，连续 2 次失败/恢复各发一条 Telegram；单用户 24h 流量超阈值提醒
- 节点侧限速按时段（`node-ph/pa-tc.sh`：平时 / 晚高峰 20–23 / 夜间 23–08 三档，watchdog 每分钟幂等应用）
- 每日备份 `relay.env` + `subscribe.db`（`subscribe/app/backup.py`，可发 Telegram）；`relay/install.sh --restore <tar.gz>` 在新 VPS 重建，WireGuard Endpoint 用域名则宿舍节点无需改动
- `docs/USER-GUIDE.md`：Clash Verge / FlClash 导入订阅步骤（文字版，截图等真机）；分组含义；常见问题
- **验证**：
  - 模拟宿舍断电 10 min：Telegram 在 2 min 内收到告警，恢复后收到恢复通知
  - 新买一台 VPS，`relay/install.sh --restore` 后用户不改订阅即可连上（订阅自动更新 host）
  - 一位没有技术背景的亲友只看 USER-GUIDE 在 5 min 内连通
  - 连续运行 7 天：无人工介入、`traffic_log` 无断档超过 5 min

### M4 · 收尾与预留（W6）

- README：架构图、各目录用途、部署顺序、运维速查表
- 备用中转 `relay-standby/`：nftables DNAT 端口转发到主中转，无状态；`pa nodes add-standby <ip>` 把"·备"节点加进所有订阅，Clash fallback 自动切换
- 体检脚本 `relay/doctor.sh`、`node-ph/doctor.sh`：排障时整段贴回
- P2 决策记录见 3.7；IPv6 直连线路见 3.8

## 3.3 测试策略

| 层 | 手段 | 覆盖 |
|---|---|---|
| 单元 | `pytest`（subscribe） | YAML 渲染快照、有效用户判定、userinfo 头、token 校验 |
| 配置 | `sing-box check` 进 CI 与 sync 流程 | 渲染出的 sing-box 配置合法 |
| 链路 | 手工，M1/M2 的验证清单 | 两条线路出口 IP、fallback 切换、重启恢复 |
| 稳定性 | 7 天挂机 + 断网/断电/重启演练 | M3 |
| 用户 | 一位国内非技术用户按 USER-GUIDE 走一遍 | M3 |

## 3.4 交付物清单

- `node-ph/`、`relay/` 一键脚本与 compose；`subscribe/` 服务（含测试）
- `docs/`：PRD / ARCHITECTURE / ROADMAP / PROBE-RESULT / USER-GUIDE
- 一条可用的订阅 URL，Clash Verge 导入后两条线路可用、自动切换、流量可见

## 3.5 需要你在编码前确认的事项

1. **规模与性质**：确认是"亲友自用、不收费、不公开"（PRD 1.0）。如果不是，先说，产品与运营部分要重写。
2. **宿舍硬件**：有没有旧笔记本？能否接网线？宿舍路由器能不能登录看 WAN 口 IP？
3. **VPS 商家与线路**：你是否已有 VPS？没有的话我按 JP 软银 / HK 普通线路给出两三个具体选项供你买。
4. **域名**：有没有现成域名可以托管到 Cloudflare？
5. **国内测试用户**：找一位愿意在晚高峰帮忙测的人。

## 3.7 P2 决策记录（商业化预留，不实现）

**触发条件**（任一满足再评估，之前不动）：用户数 > 20；要收费；需要用户自助注册/续费。

**迁移目标**：Xboard（面板、套餐、支付）+ V2bX（节点侧 agent，支持 sing-box 内核与 Hysteria2/Reality）。本项目的 `users` 表字段与其对齐，迁移是一次性脚本：

| 本项目 | Xboard |
|---|---|
| `users.uuid` | `v2_user.uuid`（VLESS） |
| `users.hy2_password` | Xboard 对 Hysteria2 统一用 uuid 作密码，迁移后用户需更新订阅 |
| `users.quota_bytes` / `used_up+used_down` | `transfer_enable` / `u`+`d` |
| `users.expire_at` | `expired_at`（unix） |
| `users.token` | `token`（订阅 token，格式不同，用户需换订阅地址） |
| `nodes` | `v2_server_*`，宿舍出口仍是本项目的 WireGuard + `ph-out` 方案，V2bX 只替换中转上的 sing-box 管理 |

**保留不变**：宿舍节点、WireGuard 隧道、`ph-out` 出站、备用中转、Telegram 告警（Xboard 没有链路级监控）。
**丢弃**：本项目的订阅服务与 `pa` 命令（被面板取代）。

**先于迁移必须做的**：法务评估（PRD 1.0）。在国内收费、推广、用微信/支付宝收款是起诉先例中的核心证据；若无法接受这个风险，P2 到此为止，维持亲友 AA。

## 3.8 IPv6 直连线路（已开发，待真机验证入站可达性）

开发机探测到宿舍 PLDT 有公网 IPv6（PROBE-RESULT 0 节），**入站可达性未验证**（路由器可能有 IPv6 防火墙）。代码已就位：

- 宿舍侧 `node-ph/v6/`：`install-v6.sh` 装官方 sing-box；`sync-v6.sh` 每分钟经 WireGuard 拉中转 `GET /internal/node`（Reality 密钥、端口、有效用户），`render.jq` 渲染配置，变了才 check + restart；同一脚本做 Cloudflare DDNS AAAA；`nftables-v6.conf.template` 只放 sing-box 端口
- 中转侧：`/internal/node` 接口（API 监听 0.0.0.0，公网 8000 被 nftables 挡，只有 wg/tailscale 能到）；`pa nodes add-v6 <host>` 复制 PH 主节点参数、`exit=ph-v6`、排最前
- 限制：这条线的流量不经中转，不计入用户配额；到期/停用仍然生效（用户列表来自中转）
- 验证：笔记本装好后跑 `install-v6.sh`，国内用户用手机流量手动选 `PH-直连 IPv6` 节点；不通先查路由器 IPv6 入站

## 3.6 编码阶段的执行顺序

方案确认后：先 `git init` + 提交 `docs/`，然后写 `scripts/probe-network.sh` 让你在宿舍跑（M0）。拿到探测数字之前不写 M1 之后的代码，因为带宽、IPv6、线路质量三个结论会直接改变 `up/down_mbps`、要不要 IPv6 直连线路、以及选哪台 VPS。每个里程碑结束按 3.2 验证项逐条核对后进入下一个。
