from datetime import datetime, timedelta, timezone

from app import models as m
from app.alerts import Alerter, traffic_last_24h


class Sup:
    running = True


def make(checks, threshold=2):
    sent = []
    a = Alerter(send=sent.append, fail_threshold=threshold, checks=checks)
    return a, sent


def test_transitions_with_threshold():
    status = {"ok": True}
    a, sent = make([("t", "隧道", lambda: (status["ok"], "detail"))])
    t0 = datetime(2026, 10, 10, tzinfo=timezone.utc)
    assert a.run_checks(Sup(), now=t0) == []
    status["ok"] = False
    assert a.run_checks(Sup(), now=t0 + timedelta(minutes=1)) == []          # 第 1 次失败不报
    msgs = a.run_checks(Sup(), now=t0 + timedelta(minutes=2))                 # 第 2 次报故障
    assert msgs == ["🔴 隧道 故障：detail"]
    assert a.run_checks(Sup(), now=t0 + timedelta(minutes=3)) == []          # 持续故障不重复报
    status["ok"] = True
    msgs = a.run_checks(Sup(), now=t0 + timedelta(minutes=12))
    assert msgs == ["✅ 隧道 已恢复（中断 10 分钟）"]
    assert sent == ["🔴 隧道 故障：detail", "✅ 隧道 已恢复（中断 10 分钟）"]


def test_flap_below_threshold_is_silent():
    seq = iter([False, True, False, True])
    a, sent = make([("t", "x", lambda: (next(seq), ""))])
    for _ in range(4):
        a.run_checks()
    assert sent == []


def test_check_exception_counts_as_failure():
    def boom():
        raise RuntimeError("no wg")

    a, sent = make([("t", "x", boom)], threshold=1)
    assert a.run_checks() == ["🔴 x 故障：检查出错: no wg"]


def test_singbox_supervisor_check():
    a, sent = make([], threshold=1)

    class Dead:
        running = False

    assert a.run_checks(Dead()) == ["🔴 sing-box 进程 故障：进程未运行"]
    assert a.run_checks(Sup())[0].startswith("✅ sing-box 进程 已恢复")


def test_traffic_warning_once_per_day(conn):
    m.create_user(conn, "alice")
    m.create_user(conn, "bob")
    now = m.utcnow()
    m.add_traffic(conn, "alice", 600, 500, ts=now - timedelta(hours=1))
    m.add_traffic(conn, "alice", 10, 10, ts=now - timedelta(hours=30))   # 超出 24h 窗口
    m.add_traffic(conn, "bob", 1, 1, ts=now)
    assert dict(traffic_last_24h(conn, now)) == {"alice": 1100, "bob": 2}
    a, sent = make([])
    assert len(a.traffic(conn, now, limit=1000)) == 1 and "alice" in sent[0]
    assert a.traffic(conn, now, limit=1000) == []                            # 同一天不重复
    tomorrow = now + timedelta(days=1)
    m.add_traffic(conn, "alice", 2000, 0, ts=tomorrow - timedelta(hours=1))
    assert len(a.traffic(conn, tomorrow, limit=1000)) == 1                   # 次日再报
    assert list(a.traffic_notified) == [tomorrow.date().isoformat()]         # 旧日期状态已清理
