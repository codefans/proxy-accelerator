import asyncio
import json
from datetime import datetime, timezone

from app import models as m
from app.sync import sync_once


class FakeSupervisor:
    def __init__(self):
        self.restarts = 0
        self.running = True

    async def restart(self):
        self.restarts += 1


def run(conn, sup, conf, stats, now=None):
    return asyncio.run(sync_once(conn, sup, fetch_stats=lambda: stats, conf_path=conf,
                                 check_fn=lambda p: None, now=now))


def _names(conf):
    return json.load(open(conf, encoding="utf-8"))["experimental"]["v2ray_api"]["stats"]["users"]


def test_first_run_records_month_without_reset(conn, singbox_conf):
    m.create_user(conn, "alice")
    m.add_traffic(conn, "alice", 5, 5)
    r = run(conn, FakeSupervisor(), singbox_conf, {})
    assert r["reset"] is False and m.meta_get(conn, "reset_month") is not None
    assert m.get_user(conn, "alice")["used_up"] == 5


def test_traffic_accumulates_and_restart_only_on_change(conn, singbox_conf):
    m.create_user(conn, "alice")
    sup = FakeSupervisor()
    r1 = run(conn, sup, singbox_conf, {"alice": (100, 200), "ghost": (1, 1)})
    assert r1["changed"] is True and sup.restarts == 1 and r1["traffic_users"] == 1
    assert _names(singbox_conf) == ["alice"]
    r2 = run(conn, sup, singbox_conf, {"alice": (1, 1)})
    assert r2["changed"] is False and sup.restarts == 1
    u = m.get_user(conn, "alice")
    assert (u["used_up"], u["used_down"]) == (101, 201)


def test_over_quota_removes_user(conn, singbox_conf):
    m.create_user(conn, "alice", quota_bytes=150)
    sup = FakeSupervisor()
    run(conn, sup, singbox_conf, {})
    assert _names(singbox_conf) == ["alice"]
    run(conn, sup, singbox_conf, {"alice": (100, 100)})
    assert _names(singbox_conf) == [] and sup.restarts == 2


def test_monthly_reset(conn, singbox_conf):
    m.create_user(conn, "alice", quota_bytes=150)
    m.add_traffic(conn, "alice", 100, 100)
    m.meta_set(conn, "reset_month", "2000-01")
    sup = FakeSupervisor()
    r = run(conn, sup, singbox_conf, {"alice": (3, 4)}, now=datetime(2026, 11, 1, 0, 0, tzinfo=timezone.utc))
    assert r["reset"] is True
    u = m.get_user(conn, "alice")
    assert (u["used_up"], u["used_down"]) == (3, 4)
    assert m.meta_get(conn, "reset_month") == "2026-11"
    assert _names(singbox_conf) == ["alice"]


def test_stats_failure_is_tolerated(conn, singbox_conf):
    m.create_user(conn, "alice")

    def boom():
        raise ConnectionError("down")

    r = asyncio.run(sync_once(conn, FakeSupervisor(), fetch_stats=boom, conf_path=singbox_conf,
                              check_fn=lambda p: None))
    assert r["traffic_users"] == 0 and r["changed"] is True
