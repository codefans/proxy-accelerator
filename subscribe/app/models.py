"""SQLite 数据层：users / nodes / traffic_log / meta。标准库 sqlite3，不用 ORM。"""
import secrets
import sqlite3
import uuid as uuidlib
from datetime import datetime, timedelta, timezone

from .config import DB_PATH

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  token TEXT UNIQUE NOT NULL,
  uuid TEXT NOT NULL,
  hy2_password TEXT NOT NULL,
  quota_bytes INTEGER NOT NULL DEFAULT 0,
  used_up INTEGER NOT NULL DEFAULT 0,
  used_down INTEGER NOT NULL DEFAULT 0,
  expire_at TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS nodes (
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  host TEXT NOT NULL,
  hy2_port INTEGER NOT NULL,
  hy2_ports TEXT NOT NULL DEFAULT '',
  vless_port INTEGER NOT NULL,
  reality_pubkey TEXT NOT NULL,
  short_id TEXT NOT NULL,
  reality_sni TEXT NOT NULL,
  hy2_sni TEXT NOT NULL,
  hy2_insecure INTEGER NOT NULL DEFAULT 1,
  up_mbps INTEGER NOT NULL DEFAULT 50,
  down_mbps INTEGER NOT NULL DEFAULT 50,
  exit TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS traffic_log (
  user_id INTEGER NOT NULL,
  ts TEXT NOT NULL,
  up INTEGER NOT NULL,
  down INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_traffic_ts ON traffic_log(ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

USER_COLUMNS = {"quota_bytes", "used_up", "used_down", "expire_at", "enabled", "note", "token"}
NODE_COLUMNS = ("name", "host", "hy2_port", "hy2_ports", "vless_port", "reality_pubkey", "short_id",
                "reality_sni", "hy2_sni", "hy2_insecure", "up_mbps", "down_mbps", "exit", "enabled", "sort")


def connect(path: str = DB_PATH) -> sqlite3.Connection:
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    return conn


# ---------- 时间 ----------
def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def parse_dt(s):
    if not s:
        return None
    dt = datetime.fromisoformat(s)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# ---------- 用户 ----------
def new_token() -> str:
    return secrets.token_hex(16)


def user_status(u, now=None) -> str:
    """ok | disabled | expired | over_quota"""
    now = now or utcnow()
    if not u["enabled"]:
        return "disabled"
    exp = parse_dt(u["expire_at"])
    if exp and exp <= now:
        return "expired"
    if u["quota_bytes"] and u["used_up"] + u["used_down"] >= u["quota_bytes"]:
        return "over_quota"
    return "ok"


def is_effective(u, now=None) -> bool:
    return user_status(u, now) == "ok"


def create_user(conn, name, quota_bytes=0, days=None, note="", uuid=None, hy2_password=None):
    now = utcnow()
    expire = iso(now + timedelta(days=days)) if days else None
    conn.execute(
        "INSERT INTO users(name, token, uuid, hy2_password, quota_bytes, expire_at, created_at, note) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (name, new_token(), uuid or str(uuidlib.uuid4()), hy2_password or secrets.token_hex(16),
         quota_bytes, expire, iso(now), note),
    )
    conn.commit()
    return get_user(conn, name)


def get_user(conn, name):
    return conn.execute("SELECT * FROM users WHERE name=?", (name,)).fetchone()


def get_user_by_token(conn, token):
    return conn.execute("SELECT * FROM users WHERE token=?", (token,)).fetchone()


def list_users(conn):
    return conn.execute("SELECT * FROM users ORDER BY id").fetchall()


def effective_users(conn, now=None):
    return [u for u in list_users(conn) if is_effective(u, now)]


def set_fields(conn, name, **fields):
    bad = set(fields) - USER_COLUMNS
    if bad:
        raise ValueError(f"不可修改的字段: {bad}")
    cols = ", ".join(f"{k}=?" for k in fields)
    cur = conn.execute(f"UPDATE users SET {cols} WHERE name=?", (*fields.values(), name))
    conn.commit()
    if cur.rowcount == 0:
        raise KeyError(name)


def delete_user(conn, name):
    u = get_user(conn, name)
    if not u:
        raise KeyError(name)
    conn.execute("DELETE FROM traffic_log WHERE user_id=?", (u["id"],))
    conn.execute("DELETE FROM users WHERE id=?", (u["id"],))
    conn.commit()


def extend_expiry(conn, name, days):
    """从 max(now, 当前到期) 起延长 days 天。"""
    u = get_user(conn, name)
    if not u:
        raise KeyError(name)
    now = utcnow()
    base = parse_dt(u["expire_at"]) or now
    base = max(base, now)
    set_fields(conn, name, expire_at=iso(base + timedelta(days=days)))


def add_traffic(conn, name, up, down, ts=None):
    u = get_user(conn, name)
    if not u:
        return False
    ts = ts or utcnow()
    conn.execute("UPDATE users SET used_up=used_up+?, used_down=used_down+? WHERE id=?", (up, down, u["id"]))
    conn.execute("INSERT INTO traffic_log(user_id, ts, up, down) VALUES (?,?,?,?)", (u["id"], iso(ts), up, down))
    conn.commit()
    return True


def reset_usage_all(conn):
    conn.execute("UPDATE users SET used_up=0, used_down=0")
    conn.commit()


def prune_traffic_log(conn, days=30):
    conn.execute("DELETE FROM traffic_log WHERE ts < ?", (iso(utcnow() - timedelta(days=days)),))
    conn.commit()


def traffic_since(conn, name, days=7):
    u = get_user(conn, name)
    if not u:
        return (0, 0)
    row = conn.execute(
        "SELECT COALESCE(SUM(up),0) AS up, COALESCE(SUM(down),0) AS down FROM traffic_log WHERE user_id=? AND ts >= ?",
        (u["id"], iso(utcnow() - timedelta(days=days))),
    ).fetchone()
    return (row["up"], row["down"])


# ---------- meta ----------
def meta_get(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row["value"] if row else None


def meta_set(conn, key, value):
    conn.execute("INSERT INTO meta(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                 (key, value))
    conn.commit()


# ---------- 节点 ----------
def list_nodes(conn, enabled_only=True):
    sql = "SELECT * FROM nodes" + (" WHERE enabled=1" if enabled_only else "") + " ORDER BY sort, id"
    return conn.execute(sql).fetchall()


def upsert_node(conn, **n):
    missing = set(NODE_COLUMNS) - set(n) - {"hy2_ports", "hy2_insecure", "up_mbps", "down_mbps", "enabled", "sort"}
    if missing:
        raise ValueError(f"节点缺少字段: {missing}")
    cols = [c for c in NODE_COLUMNS if c in n]
    placeholders = ", ".join("?" for _ in cols)
    updates = ", ".join(f"{c}=excluded.{c}" for c in cols if c != "name")
    conn.execute(
        f"INSERT INTO nodes({', '.join(cols)}) VALUES ({placeholders}) ON CONFLICT(name) DO UPDATE SET {updates}",
        [n[c] for c in cols],
    )
    conn.commit()


def get_node(conn, name):
    return conn.execute("SELECT * FROM nodes WHERE name=?", (name,)).fetchone()


def delete_node(conn, name):
    cur = conn.execute("DELETE FROM nodes WHERE name=?", (name,))
    conn.commit()
    if cur.rowcount == 0:
        raise KeyError(name)


def add_standby(conn, host, suffix="备", bases=("PH-宿舍", "HK-中转")):
    """按主节点复制一份指向备用中转的节点：同协议参数、不同 host、排在主节点之后。返回新建的名字。"""
    names = []
    for base in bases:
        n = get_node(conn, base)
        if not n:
            continue
        row = dict(n)
        row.pop("id")
        row.update(name=f"{base}·{suffix}", host=host, sort=n["sort"] + 1, enabled=1)
        upsert_node(conn, **row)
        names.append(row["name"])
    return names


def add_v6_node(conn, host, base="PH-宿舍", name="PH-直连 IPv6"):
    """IPv6 直连节点：复制宿舍主节点的协议参数（同一套 Reality 密钥），host 为宿舍的 AAAA 域名，排在最前。"""
    n = get_node(conn, base)
    if not n:
        raise KeyError(base)
    row = dict(n)
    row.pop("id")
    row.update(name=name, host=host, exit="ph-v6", hy2_insecure=1, sort=n["sort"] - 1, enabled=1)
    upsert_node(conn, **row)
    return name


def read_env_file(path) -> dict:
    """KEY=VALUE 文件 → dict（relay.env / node.env）"""
    from pathlib import Path

    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def set_node_enabled(conn, name, enabled):
    cur = conn.execute("UPDATE nodes SET enabled=? WHERE name=?", (1 if enabled else 0, name))
    conn.commit()
    if cur.rowcount == 0:
        raise KeyError(name)


# ---------- 大小 ----------
_UNITS = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}


def parse_size(s: str) -> int:
    """'100G' / '1.5T' / '500M' / '0' → 字节。"""
    s = s.strip().upper().rstrip("B")
    unit = s[-1] if s and s[-1] in _UNITS else ""
    num = s[:-1] if unit else s
    return int(float(num) * _UNITS[unit])


def fmt_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} TB"
