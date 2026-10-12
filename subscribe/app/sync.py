"""每 60 秒一次：拉流量 → 累加 → 月初归零 → 计算有效用户 → 写 sing-box 配置 → 有变化才重启。"""
import asyncio
import logging
from zoneinfo import ZoneInfo

from .config import RESET_TZ, SINGBOX_CONF
from .models import (add_traffic, effective_users, meta_get, meta_set, prune_traffic_log,
                     reset_usage_all, utcnow)
from .render import singbox_users
from .singbox import check, write_users
from .stats import query_user_traffic

log = logging.getLogger("pa.sync")


async def sync_once(conn, supervisor, fetch_stats=query_user_traffic, conf_path=SINGBOX_CONF,
                    check_fn=check, now=None) -> dict:
    now = now or utcnow()
    result = {"traffic_users": 0, "changed": False, "reset": False}

    # 1. 月初归零（按 RESET_TZ 的自然月；首次运行只记录月份）
    month = now.astimezone(ZoneInfo(RESET_TZ)).strftime("%Y-%m")
    last = meta_get(conn, "reset_month")
    if last != month:
        if last is not None:
            reset_usage_all(conn)
            result["reset"] = True
            log.info("新月份 %s，流量计数归零", month)
        meta_set(conn, "reset_month", month)

    # 2. 流量累加（sing-box 没起来或刚重启时拿不到，跳过即可）
    try:
        traffic = await asyncio.get_running_loop().run_in_executor(None, fetch_stats)
    except Exception as e:  # noqa: BLE001
        log.warning("拉取流量统计失败: %s", e)
        traffic = {}
    for name, (up, down) in traffic.items():
        if (up or down) and add_traffic(conn, name, up, down, now):
            result["traffic_users"] += 1
    prune_traffic_log(conn)

    # 3. 有效用户 → sing-box
    hy2, vless, names = singbox_users(effective_users(conn, now))
    if write_users(hy2, vless, names, conf_path=conf_path, check_fn=check_fn):
        result["changed"] = True
        log.info("有效用户变为 %s", names)
        await supervisor.restart()
    return result
