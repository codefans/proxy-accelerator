"""订阅服务：GET /sub/<token>、GET /healthz、POST /internal/sync。
进程内同时：看护 sing-box 子进程、每 60 秒同步用户与流量、健康检查告警、每日备份。"""
import asyncio
import logging
import re
from contextlib import asynccontextmanager, closing

from fastapi import FastAPI, HTTPException, Response

from .alerts import Alerter
from .backup import maybe_daily_backup
from .config import API_HOST, API_PORT, RELAY_ENV, SUB_FILENAME, SYNC_INTERVAL
from .models import connect, effective_users, get_user_by_token, list_nodes, read_env_file
from .notify import telegram_send
from .render import render_clash, userinfo_header
from .singbox import Supervisor
from .sync import sync_once

log = logging.getLogger("pa")
state: dict = {}
TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")


@asynccontextmanager
async def lifespan(_app):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    loop = asyncio.get_running_loop()
    conn = connect()
    sup = Supervisor()
    await sup.start()
    alerter = Alerter()
    state.update(conn=conn, sup=sup, lock=asyncio.Lock())
    await loop.run_in_executor(None, telegram_send, "🟢 relay 已启动")

    async def periodic():
        while True:
            try:
                async with state["lock"]:
                    await sync_once(conn, sup)
                    await loop.run_in_executor(None, alerter.run_checks, sup)
                    alerter.traffic(conn)
                    await loop.run_in_executor(None, maybe_daily_backup, conn)
            except Exception:  # noqa: BLE001
                log.exception("周期任务失败")
            await asyncio.sleep(SYNC_INTERVAL)

    task = asyncio.create_task(periodic())
    try:
        yield
    finally:
        task.cancel()
        await sup.stop()
        conn.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/sub/{token}")
def subscription(token: str):
    if not TOKEN_RE.match(token):
        raise HTTPException(404)
    # 请求线程用自己的连接，不和周期任务共享
    with closing(connect()) as conn:
        user = get_user_by_token(conn, token)
        if not user:
            raise HTTPException(404)
        body = render_clash(user, list_nodes(conn))
    headers = {
        "subscription-userinfo": userinfo_header(user),
        "profile-update-interval": "12",
        "content-disposition": f"attachment; filename*=UTF-8''{SUB_FILENAME}",
        "cache-control": "no-store",
    }
    return Response(body, media_type="text/yaml; charset=utf-8", headers=headers)


@app.get("/healthz")
def healthz():
    sup = state.get("sup")
    return {"status": "ok", "singbox": bool(sup and sup.running)}


@app.post("/internal/sync")
async def internal_sync():
    async with state["lock"]:
        return await sync_once(state["conn"], state["sup"])


NODE_ENV_KEYS = ("REALITY_PRIVATE_KEY", "REALITY_PUBLIC_KEY", "SHORT_ID", "REALITY_SNI", "SNI",
                 "HY2_PH_PORT", "VLESS_PH_PORT", "HOP_PORTS", "UP_MBPS", "DOWN_MBPS")


@app.get("/internal/node")
def internal_node():
    """宿舍节点（IPv6 直连线路）每分钟经 WireGuard 拉：协议参数 + 当前有效用户。只在 wg/tailscale 网段可达。"""
    env = read_env_file(RELAY_ENV)
    with closing(connect()) as conn:
        users = [{"name": u["name"], "uuid": u["uuid"], "hy2_password": u["hy2_password"]}
                 for u in effective_users(conn)]
        v6 = [n["host"] for n in list_nodes(conn) if n["exit"] == "ph-v6"]
    return {"version": 1, "params": {k: env.get(k, "") for k in NODE_ENV_KEYS}, "users": users,
            "v6_host": v6[0] if v6 else ""}


def main():
    import uvicorn

    uvicorn.run(app, host=API_HOST, port=API_PORT, log_level="warning")


if __name__ == "__main__":
    main()
