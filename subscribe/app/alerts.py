"""健康检查与告警：隧道握手、宿舍出口上网、中转自身上网、sing-box 存活、单用户流量异常。

每 60 秒随同步循环跑一次；连续 fail_threshold 次失败才算故障，状态翻转（故障/恢复）时各发一条通知。
"""
import logging
import subprocess
import time
from datetime import timedelta

from .config import HANDSHAKE_MAX_AGE, TRAFFIC_WARN_BYTES, WG_IFACE
from .models import fmt_size, iso, utcnow
from .notify import telegram_send

log = logging.getLogger("pa.alerts")
PROBE_URL = "https://www.gstatic.com/generate_204"


# ---------- 单项检查：返回 (ok, 说明) ----------
def check_tunnel(iface: str = WG_IFACE, max_age: int = HANDSHAKE_MAX_AGE):
    r = subprocess.run(["wg", "show", iface, "latest-handshakes"], capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"wg show 失败: {(r.stderr or r.stdout).strip()}"
    parts = r.stdout.split()
    last = int(parts[1]) if len(parts) >= 2 else 0
    age = int(time.time()) - last
    if last == 0:
        return False, "从未握手"
    return age <= max_age, f"上次握手 {age}s 前"


def _curl(iface=None, timeout: int = 10):
    cmd = ["curl", "-4", "-s", "-m", str(timeout), "-o", "/dev/null", "-w", "%{http_code}", PROBE_URL]
    if iface:
        cmd[1:1] = ["--interface", iface]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.stdout.strip() == "204"
    return ok, ("HTTP " + r.stdout.strip()) if r.stdout.strip() else "无响应"


def check_ph_exit():
    return _curl(WG_IFACE)


def check_relay_exit():
    return _curl(None)


CHECKS = [
    ("tunnel", "宿舍隧道 WireGuard", check_tunnel),
    ("ph_exit", "宿舍出口上网", check_ph_exit),
    ("relay_exit", "中转自身上网", check_relay_exit),
]


class Alerter:
    def __init__(self, send=telegram_send, fail_threshold: int = 2, checks=None):
        self.send = send
        self.threshold = fail_threshold
        self.checks = checks if checks is not None else CHECKS
        self.state = {}        # name -> {"ok": bool, "fails": int, "since": datetime|None}
        self.traffic_notified = {}  # date -> set(user)

    def observe(self, name: str, label: str, ok: bool, detail: str = "", now=None):
        """记录一次观测；需要通知时返回消息文本。"""
        now = now or utcnow()
        st = self.state.setdefault(name, {"ok": True, "fails": 0, "since": None})
        if ok:
            st["fails"] = 0
            if not st["ok"]:
                st["ok"] = True
                dur = now - st["since"] if st["since"] else timedelta(0)
                msg = f"✅ {label} 已恢复（中断 {int(dur.total_seconds() // 60)} 分钟）"
                self.send(msg)
                return msg
            return None
        st["fails"] += 1
        if st["ok"] and st["fails"] >= self.threshold:
            st["ok"] = False
            st["since"] = now
            msg = f"🔴 {label} 故障：{detail}"
            self.send(msg)
            return msg
        return None

    def run_checks(self, supervisor=None, now=None):
        """阻塞（跑 wg/curl 子进程），在线程池里调用。返回发出的消息列表。"""
        sent = []
        if supervisor is not None:
            m = self.observe("singbox", "sing-box 进程", supervisor.running, "进程未运行", now)
            if m:
                sent.append(m)
        for name, label, fn in self.checks:
            try:
                ok, detail = fn()
            except Exception as e:  # noqa: BLE001
                ok, detail = False, f"检查出错: {e}"
            m = self.observe(name, label, ok, detail, now)
            if m:
                sent.append(m)
        return sent

    def traffic(self, conn, now=None, limit: int = TRAFFIC_WARN_BYTES):
        """24 小时内流量超过阈值的用户，每人每天只提醒一次。"""
        now = now or utcnow()
        today = now.date().isoformat()
        done = self.traffic_notified.setdefault(today, set())
        for d in [k for k in self.traffic_notified if k != today]:
            del self.traffic_notified[d]
        sent = []
        for name, total in traffic_last_24h(conn, now):
            if total > limit and name not in done:
                done.add(name)
                msg = f"⚠️ 用户 {name} 24 小时用了 {fmt_size(total)}，超过 {fmt_size(limit)}"
                self.send(msg)
                sent.append(msg)
        return sent


def traffic_last_24h(conn, now=None):
    now = now or utcnow()
    rows = conn.execute(
        "SELECT u.name AS name, SUM(t.up + t.down) AS total FROM traffic_log t JOIN users u ON u.id = t.user_id "
        "WHERE t.ts >= ? GROUP BY u.name", (iso(now - timedelta(hours=24)),)
    ).fetchall()
    return [(r["name"], r["total"]) for r in rows]
