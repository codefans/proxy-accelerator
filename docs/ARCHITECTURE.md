# 技术架构方案

## 2.1 总体架构

```
 中国大陆用户 (Clash Verge / mihomo)
   │  订阅:  GET https://sub.<domain>/sub/<token>   ← Cloudflare 代理，和中转 IP 解耦
   │  流量:  Hysteria2 (UDP, 端口跳跃 20000-30000→443)  /  VLESS+Reality (TCP 443)
   ▼
┌──────────────────── 入口中转 VPS (HK/JP, Debian 12) ────────────────────┐
│  sing-box (多用户)                                                       │
│   inbounds:  hy2-ph  (UDP 443)   vless-ph (TCP 443)   → 出站 ph-out     │
│              hy2-hk  (UDP 8443)  vless-hk (TCP 8443)  → 出站 direct     │
│   outbounds: ph-out = direct + bind_interface wg0 ──┐   direct          │
│   v2ray_api: 按用户流量统计 (gRPC 127.0.0.1:10085)   │                   │
│                                                      │                   │
│  kernel WireGuard wg0 10.9.0.1/24, listen 51820 ◄────┘                   │
│  订阅服务 subscribe (FastAPI + SQLite, 127.0.0.1:8000) ← Caddy 2053 TLS  │
│   同一进程拉起并看护 sing-box 子进程（同一容器 relay）                       │
│   每 60s: 拉流量统计 → 累加到 DB → 计算有效用户 → 渲染 users[] → 变更才重启  │
│  nftables: 443/8443 tcp+udp, 51820 udp, 20000-30000 udp redirect→443     │
└───────────────────────────────▲──────────────────────────────────────────┘
                                │ WireGuard UDP (宿舍节点主动外连, keepalive 25s, 穿 CGNAT)
┌───────────────────────────────┴──────────────────────────────────────────┐
│  宿舍出口节点 (PH, 旧笔记本/N100, Debian 12)                               │
│   wg0 10.9.0.2/24, Endpoint=<relay>:51820, AllowedIPs=10.9.0.1/32        │
│   ip_forward=1; nft masquerade: wg0 → eth0/wlan0 (宿舍 WiFi) → 互联网     │
│   tc 限速 (上行 60–70%)；封 25/tcp、BT 端口                                │
│   Tailscale (管理 SSH)；watchdog.service (握手超时→重启 wg；无网→重启网卡)   │
│   BIOS 来电自启；笔记本合盖不休眠                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

**数据流**：用户 → (hy2/reality 加密) → 中转解密 → 经 wg0 (WireGuard 再加密) → 宿舍节点解密 → NAT → 宿舍 WiFi → 目标网站。目标网站看到的是宿舍的住宅 IP。

**为什么协议在中转终结、而不是在宿舍终结**（两种方案都可行，选前者）：

| | 中转终结（本方案） | 宿舍终结（中转只做端口转发 realm/frp） |
|---|---|---|
| 宿舍掉线时 | 中转自身出口可兜底，用户仍能用 | 全断 |
| 用户/流量统计 | 集中在中转一处 | 在宿舍，CGNAT 后面不好访问 |
| 宿舍节点复杂度 | 极低（wg + nat），坏了重装 10 分钟 | 要跑 sing-box 多用户 |
| 中转能看到流量明文 | 是（自己的 VPS，可接受） | 否 |

**第三条线路 IPv6 直连（`node-ph/v6/`，已实现）**：宿舍节点再跑一个官方 sing-box 监听公网 IPv6，与中转共用同一套 Reality 密钥，用户列表和参数每分钟经 WireGuard 从中转 `GET /internal/node` 拉取，Cloudflare DDNS 维护 AAAA。订阅里 `PH-直连 IPv6` 排最前，国内有 IPv6 的用户少一跳、不占中转流量；没 IPv6 的用户健康检查失败自动落到中转线路。此线路流量不经中转，不计入配额。

## 2.2 技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| 代理内核（中转） | sing-box 最新 stable，**自编译带 `with_v2ray_api`**（官方二进制不含该 tag，无法按用户统计流量） | 与旁边项目一致，Reality/Hysteria2/Clash API 齐全；Dockerfile 一行 build-arg |
| 隧道（中转↔宿舍） | kernel WireGuard | 内核态性能最好、穿 NAT 稳定、配置 10 行；sing-box 出站用 `bind_interface: wg0` 即可，不需要策略路由 |
| 订阅服务 | Python 3.12 + FastAPI + SQLite + Jinja2，Docker 部署 | 与你现有 Python 工具栈一致；总代码量 ~300 行；SQLite 单文件备份 |
| 反代 / TLS | Caddy，监听 **2053**（TCP 443 被 Reality 占用）；Cloudflare 橙云 + Origin Rule 把 443 改写到 2053，用户仍访问 `https://sub.<domain>/...`；证书用 Cloudflare Origin CA | 一行配置；2053 是 Cloudflare 支持代理的端口 |
| 订阅域名 | Cloudflare 橙云代理 | 国内可达，隐藏中转 IP；中转换 IP 不影响订阅 |
| 远程管理 | Tailscale | 宿舍节点 CGNAT 后仍可 SSH |
| 客户端 | Clash Verge Rev（mihomo 内核） | 用户自装，零开发；订阅格式为 Clash Meta YAML |
| 监控与备份（M3） | 订阅服务进程内：每 60 秒检查 wg 握手 / 经隧道出网 / 中转出网 / sing-box 存活，状态翻转发 Telegram；每日 04:00 备份 relay.env + subscribe.db，可发 Telegram | 比 Uptime Kuma 少一个要在网页里手工配的组件；标准库实现 Bot API |

## 2.3 代码结构

```
proxy-accelerator/
├─ docs/                    PRD.md · ARCHITECTURE.md · ROADMAP.md · USER-GUIDE.md(用户导入教程)
├─ scripts/
│  └─ probe-network.sh      Phase 0：在宿舍跑，输出 公网IPv4?/CGNAT?/IPv6?/上下行带宽/到候选VPS延迟
├─ node-ph/                 宿舍出口节点
│  ├─ install.sh            apt wireguard nftables tailscale → 渲染 wg0.conf → 开 ip_forward → nft 规则 → tc 限速 → watchdog → 来电自启提示
│  ├─ wg0.conf.template
│  ├─ nftables.conf         masquerade + 封 25/tcp + BT 端口
│  ├─ watchdog.sh + .service/.timer   每 60s：wg 最近握手 > 3min → restart wg-quick@wg0；ping 网关失败 → 重启网络
│  └─ README.md
├─ relay/                   入口中转
│  ├─ install.sh            构建 relay 镜像 + wg server + nftables + compose up + pa 命令 + 首个用户；输出宿舍节点的 wg 配置
│  ├─ Dockerfile            两阶段：golang 编译 sing-box（-tags with_v2ray_api,...）→ python:slim + 订阅服务
│  ├─ docker-compose.yml    relay（sing-box + 订阅服务，host 网络）· caddy（2053）
│  ├─ Caddyfile
│  ├─ sing-box/config.template.json
│  ├─ wg0.conf.template     Table = off（不接管路由，只做 cryptokey routing）
│  ├─ nftables.conf.template
│  └─ doctor.sh             一键体检
├─ relay-standby/           备用中转：install.sh 用 nftables DNAT 把 443/8443/跳跃段转发到主中转，无状态
├─ subscribe/               订阅服务（唯一需要"开发"的部分）
│  ├─ app/
│  │  ├─ main.py            FastAPI：GET /sub/<token>  GET /healthz  POST /internal/sync；lifespan 里拉起 sing-box 与同步循环
│  │  ├─ models.py          SQLite schema（users / nodes / traffic_log / meta）、有效用户判定
│  │  ├─ stats.py           v2ray_api gRPC 客户端（手工 protobuf 编解码，只依赖 grpcio）
│  │  ├─ render.py          Jinja2 → Clash YAML；subscription-userinfo 头；sing-box users[]
│  │  ├─ singbox.py         Supervisor（子进程看护）+ write_users（diff → check → 替换）
│  │  ├─ sync.py            sync_once：拉统计 → 累加 → 月初归零 → 有效用户 → 写配置 → 变更才重启
│  │  └─ cli.py             pa adduser / del / renew / quota / enable / disable / reset-token / list / stats / url / clash / nodes / import-m1
│  ├─ templates/clash.yaml.j2
│  ├─ tests/                stats 编解码、模型、渲染、write_users、sync、API
│  ├─ pa                    容器内 CLI 入口
│  ├─ requirements.txt · requirements-dev.txt · README.md
└─ README.md
```

**从旁边项目直接复用**：`freely-access-to-china-network/server/exit-node/` 的 `install.sh`（凭据生成、Reality 密钥对、自签/ACME、BBR）、`config.template.json`（hy2 + vless 入站结构）、`print-links.sh`。本项目的 `relay/install.sh` 以它为底改：入站 ×2（ph / hk 两组端口）、加 `v2ray_api`、加 `ph-out` 出站与 route 规则；`add-user.sh` 的职责改由 `subscribe/cli.py` 承担。

## 2.4 数据模型（SQLite）

```sql
users (
  id INTEGER PK, name TEXT UNIQUE, token TEXT UNIQUE,      -- token: 32 hex，订阅 URL 凭据，可重置
  uuid TEXT, hy2_password TEXT,                             -- sing-box 侧凭据
  quota_bytes INTEGER, used_up INTEGER, used_down INTEGER,  -- 配额与累计（每月 1 日由 sync 归零，或手动）
  expire_at TEXT, enabled INTEGER DEFAULT 1,
  created_at TEXT, note TEXT
)
nodes (
  id INTEGER PK, name TEXT, host TEXT,                      -- host: 中转域名或 IP
  hy2_port INTEGER, hy2_ports TEXT,                         -- "20000-30000" 端口跳跃段
  vless_port INTEGER, reality_pubkey TEXT, short_id TEXT, sni TEXT,
  hy2_sni TEXT, hy2_insecure INTEGER,
  exit TEXT,                                                -- "ph" | "hk" | "ph-v6"
  enabled INTEGER DEFAULT 1, sort INTEGER
)
traffic_log ( user_id, ts, up, down )                       -- 每 60s 一行，保留 30 天
```

**有效用户** = `enabled=1 AND expire_at > now AND (quota_bytes=0 OR used_up+used_down < quota_bytes)`。只有有效用户会出现在 sing-box 的 `users[]` 里；无效用户的订阅仍能拉到（显示"已到期/超额"的空节点列表 + 提示），但连不上。

## 2.5 中转 sing-box 配置要点

```jsonc
{
  "experimental": {
    "v2ray_api": { "listen": "127.0.0.1:10085", "stats": { "enabled": true, "users": ["<每个有效用户名>"] } }
  },
  "inbounds": [
    { "type": "hysteria2", "tag": "hy2-ph", "listen": "::", "listen_port": 443,
      "up_mbps": 50, "down_mbps": 50,                     // 按宿舍实测上行设置，影响 Brutal 拥塞控制
      "obfs": { "type": "salamander", "password": "…" },  // 可选，UDP 被 QoS 严重时开
      "users": [ { "name": "alice", "password": "…" } ],
      "masquerade": "https://www.bing.com",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "…", "key_path": "…" } },
    { "type": "vless", "tag": "vless-ph", "listen": "::", "listen_port": 443,
      "users": [ { "name": "alice", "uuid": "…", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "www.microsoft.com",
               "reality": { "enabled": true, "handshake": { "server": "www.microsoft.com", "server_port": 443 },
                            "private_key": "…", "short_id": ["…"] } } },
    { "...": "hy2-hk / vless-hk 同上，端口 8443" }
  ],
  "outbounds": [
    { "type": "direct", "tag": "ph-out", "bind_interface": "wg0" },   // 走 WireGuard 到宿舍
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": ["hy2-ph", "vless-ph"], "outbound": "ph-out" },
      { "inbound": ["hy2-hk", "vless-hk"], "outbound": "direct" }
    ],
    "final": "direct"
  }
}
```

- `users[]` 由 `subscribe/sync.py` 渲染写入，sing-box 不支持热加载用户 → 变更时 `sing-box check` 后 `docker restart`（秒级抖动，分钟粒度合并变更）。
- 端口跳跃：nftables `udp dport 20000-30000 redirect to :443`；客户端 `ports: 20000-30000`。
- 中转 wg0：`Address 10.9.0.1/24, ListenPort 51820, Table = off`；peer 宿舍 `AllowedIPs 0.0.0.0/0, ::/0`（不写 Endpoint，由宿舍主动握手后学习）。`Table = off` 保证 0.0.0.0/0 不进系统路由表，只做 cryptokey routing，中转自身出口不受影响。
- 宿舍 wg0：`Address 10.9.0.2/24`，peer 中转 `Endpoint <relay>:51820, AllowedIPs 10.9.0.1/32, PersistentKeepalive 25`。只有去中转 wg IP 的流量进隧道；从隧道来的流量（目标为互联网）经 `ip_forward` + masquerade 出宿舍 WiFi。
- MTU：wg0 1420；Hysteria2 在其上跑 QUIC 无需额外调整。

## 2.6 订阅输出（Clash Meta YAML）

```yaml
# HTTP 头: subscription-userinfo: upload=…; download=…; total=…; expire=<unix>
#          profile-update-interval: 12   content-disposition: attachment; filename=ph-dorm.yaml
mixed-port: 7890
mode: rule
dns: { enable: true, enhanced-mode: fake-ip, nameserver: [223.5.5.5, 119.29.29.29],
       fallback: [https://1.1.1.1/dns-query], fallback-filter: { geoip: true, geoip-code: CN } }
proxies:
  - { name: "PH-宿舍 hy2",  type: hysteria2, server: <host>, port: 443, ports: 20000-30000,
      password: <hy2_password>, sni: <sni>, skip-cert-verify: <insecure>, up: 50, down: 50 }
  - { name: "PH-宿舍 reality", type: vless, server: <host>, port: 443, uuid: <uuid>, flow: xtls-rprx-vision,
      tls: true, servername: www.microsoft.com, client-fingerprint: chrome,
      reality-opts: { public-key: <pubkey>, short-id: <short_id> } }
  - { name: "HK-中转 hy2", …port: 8443… }
  - { name: "HK-中转 reality", …port: 8443… }
proxy-groups:
  - { name: "🚀 节点选择", type: select, proxies: ["♻️ 自动(PH优先)", "PH-宿舍 hy2", "PH-宿舍 reality", "HK-中转 hy2", "HK-中转 reality", DIRECT] }
  - { name: "♻️ 自动(PH优先)", type: fallback, url: https://www.gstatic.com/generate_204, interval: 60,
      proxies: ["PH-宿舍 hy2", "PH-宿舍 reality", "HK-中转 hy2", "HK-中转 reality"] }
  - { name: "🤖 AI 服务", type: select, proxies: ["PH-宿舍 hy2", "PH-宿舍 reality", "🚀 节点选择"] }  # 固定走住宅 IP
rule-providers: (geosite cn / geoip cn / 常用 AI 域名列表，远程 .mrs，经代理更新)
rules:
  - RULE-SET,ai,🤖 AI 服务
  - GEOSITE,cn,DIRECT
  - GEOIP,cn,DIRECT,no-resolve
  - GEOIP,private,DIRECT,no-resolve
  - MATCH,🚀 节点选择
```

- `fallback` 组按顺序健康检查：宿舍断线时 `PH-宿舍` 两条探测失败，自动落到 `HK-中转`；恢复后自动切回。
- AI 服务固定走 PH（住宅 IP），不受 fallback 影响；宿舍掉线时用户手动切或接受不可用。
- 模板用 Jinja2 渲染，用户相关字段只有 `password / uuid`；节点字段来自 `nodes` 表，换 VPS 只需改表。

## 2.7 流量统计与同步（`sync.py`，每 60s）

1. gRPC 调 v2ray_api `QueryStats(pattern="user>>>", reset=true)` → 得到每用户本周期 uplink/downlink 增量
2. 累加到 `users.used_up/used_down`，追加 `traffic_log`
3. 计算有效用户集合；与当前 `config.json` 的 `users[]` 对比
4. 有差异 → 写 `config.json.new` → `sing-box check` → 原子替换 → 重启 sing-box 子进程（4 个入站 users 同步更新）
5. 每月 1 日 00:00（北京时间）归零 `used_*`，月份记在 `meta` 表

同一进程里一个 asyncio 循环跑，不引入调度库和消息队列；CLI 改完数据后 `POST /internal/sync` 让它立刻执行一次。gRPC 调用用 `grpcio` 的通用 unary 接口，QueryStats 的请求/响应只有两条小消息，手工编解码 protobuf，不生成 stub。sing-box 作为订阅服务的子进程运行（同一容器），重启不需要 Docker socket。

## 2.8 宿舍节点要点

- **网络接入**：优先网线；WiFi 时用 NetworkManager `autoconnect-priority` + `connection.autoconnect-retries=0`（无限重试）
- **NAT**：`nft add rule ip nat postrouting oifname "eth0" masquerade`；`net.ipv4.ip_forward=1`；`rp_filter=2`
- **限速**：`tc qdisc add dev eth0 root tbf rate 40mbit burst 32kbit latency 400ms`（值按 Phase 0 实测 × 0.65；P1 改按时段）
- **封端口**：出站 `tcp dport 25 drop`；`tcp/udp dport 6881-6889 drop`
- **watchdog**（systemd timer 每 60s）：`wg show wg0 latest-handshakes` 超 180s → `systemctl restart wg-quick@wg0`；连续 3 次 ping 网关失败 → `nmcli networking off/on`；连续 10 分钟无网 → `reboot`
- **电源**：BIOS "AC Power Recovery = On"；笔记本 `HandleLidSwitch=ignore`；电池掉到 5% 时 `systemd` 正常关机避免损坏文件系统
- **管理**：Tailscale SSH；`unattended-upgrades` 只装安全更新；sing-box 不在此节点（除非启用 IPv6 直连线路）

## 2.9 安全与隐私

- 中转只开 443/8443 tcp+udp、2053/tcp、51820/udp、20000-30000/udp；SSH 默认公网 + fail2ban，`SSH_VIA_TAILSCALE=1` 后仅 tailscale0；有密钥时关闭密码登录；unattended-upgrades 安全更新（中转与宿舍节点都装）
- CI（GitHub Actions）：pytest、shellcheck、四份 nftables 规则 `nft -c`、sing-box 配置 `check`、relay 镜像完整构建并用自编译 sing-box 校验含 v2ray_api 的配置
- 订阅服务只监听 127.0.0.1，Caddy 反代；token 32 字节随机，泄露即 `cli.py reset-token`
- WireGuard 预共享密钥（PSK）开启；密钥不入库
- sing-box 日志 `level: warn`，**不记录访问目标域名**；`traffic_log` 只有字节数
- 中转上 `cron` 每日备份 `subscribe.db` 到 Cloudflare R2 / 另一台机（P1）
- 所有凭据由 `install.sh` 生成并写 `.env`（`.gitignore`），仓库里只有模板

## 2.10 关键技术风险与对策

| 风险 | 对策 |
|---|---|
| 官方 sing-box 不带 `v2ray_api`，统计拿不到 | 自编译镜像（Dockerfile 已定）；验证项：`grpcurl` 能查到 `user>>>alice>>>traffic>>>uplink` |
| `bind_interface: wg0` 在容器里不生效 | sing-box 容器 `network_mode: host`（本来就需要监听多端口）；验证 `curl --interface wg0 ip.sb` 返回 PH IP |
| WireGuard 经宿舍 NAT 被超时踢掉 | `PersistentKeepalive 25`；watchdog 兜底 |
| Hysteria2 `up/down_mbps` 设得比宿舍实际上行高 → Brutal 打爆链路反而丢包 | 设为实测值 × 0.8；客户端侧也写相同值 |
| 中转 VPS 商家禁止代理（如阿里云 HK） | 选 DMIT/搬瓦工等明确允许的商家；`relay/install.sh` 支持 30 分钟内整机重建 |
| Cloudflare 橙云在国内偶发慢/不通 | 订阅只是一次性拉取，慢可接受；备用：`sub2.<domain>` 灰云直指中转 |
| 用户把 PH 线路当下载线路打满上行 | 节点 tc 限速 + 每用户配额；P1 加每用户限速 |

---
