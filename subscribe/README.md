# subscribe · 订阅服务

跑在 relay 容器里（见 `relay/Dockerfile`），同一进程做三件事：

1. **HTTP**（127.0.0.1:8000，Caddy 反代到 2053）：`GET /sub/<token>` 返回 Clash Meta YAML，带 `subscription-userinfo`（Clash Verge 显示流量与到期）；`GET /healthz`；`POST /internal/sync`（CLI 用）
2. **看护 sing-box**：作为子进程拉起，意外退出 2 秒后重启；用户变更时 `check` 后重启
3. **每 60 秒同步**：v2ray_api 拉各用户流量 → 累加到 SQLite → 月初归零（北京时间）→ 有效用户写回 `config.json` 的 `users[]` → 有变化才重启

```
app/config.py    路径与端口，全部可用 PA_* 环境变量覆盖
app/models.py    SQLite：users / nodes / traffic_log / meta；有效用户判定
app/stats.py     v2ray_api 客户端（手工 protobuf 编解码，只依赖 grpcio）
app/render.py    Clash YAML / userinfo 头 / sing-box users[]
app/singbox.py   Supervisor + write_users
app/sync.py      sync_once
app/main.py      FastAPI + lifespan
app/cli.py       pa 命令
templates/clash.yaml.j2
tests/
```

本地测试（不需要 sing-box、grpcio）：

```bash
cd subscribe && pip install -r requirements-dev.txt && pytest -q
```

本地跑 CLI 看效果：

```bash
PA_DB=/tmp/t.db PA_RELAY_ENV=/path/to/relay.env python -m app.cli nodes sync-env
PA_DB=/tmp/t.db python -m app.cli adduser alice --quota 100G
PA_DB=/tmp/t.db python -m app.cli clash alice
```
