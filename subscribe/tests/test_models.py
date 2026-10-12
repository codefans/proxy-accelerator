from datetime import timedelta

import pytest

from app import models as m
from tests.conftest import node_dict


def test_create_user_defaults(conn):
    u = m.create_user(conn, "alice")
    assert len(u["token"]) == 32 and len(u["hy2_password"]) == 32 and "-" in u["uuid"]
    assert u["quota_bytes"] == 0 and u["expire_at"] is None and u["enabled"] == 1
    assert m.user_status(u) == "ok"


def test_status_transitions(conn):
    m.create_user(conn, "a", quota_bytes=1000, days=30)
    assert m.user_status(m.get_user(conn, "a")) == "ok"
    m.set_fields(conn, "a", enabled=0)
    assert m.user_status(m.get_user(conn, "a")) == "disabled"
    m.set_fields(conn, "a", enabled=1)
    m.add_traffic(conn, "a", 600, 400)
    assert m.user_status(m.get_user(conn, "a")) == "over_quota"
    m.set_fields(conn, "a", quota_bytes=0)
    assert m.user_status(m.get_user(conn, "a")) == "ok"
    m.set_fields(conn, "a", expire_at=m.iso(m.utcnow() - timedelta(seconds=1)))
    assert m.user_status(m.get_user(conn, "a")) == "expired"
    assert m.effective_users(conn) == []


def test_extend_expiry_from_past(conn):
    m.create_user(conn, "a")
    m.set_fields(conn, "a", expire_at=m.iso(m.utcnow() - timedelta(days=10)))
    m.extend_expiry(conn, "a", 30)
    exp = m.parse_dt(m.get_user(conn, "a")["expire_at"])
    assert abs((exp - m.utcnow()).days - 30) <= 1


def test_traffic_log_and_window(conn):
    m.create_user(conn, "a")
    m.add_traffic(conn, "a", 10, 20)
    m.add_traffic(conn, "a", 1, 2, ts=m.utcnow() - timedelta(days=10))
    assert m.traffic_since(conn, "a", 7) == (10, 20)
    m.prune_traffic_log(conn, days=7)
    assert conn.execute("SELECT COUNT(*) FROM traffic_log").fetchone()[0] == 1
    m.reset_usage_all(conn)
    assert m.get_user(conn, "a")["used_up"] == 0


def test_set_fields_rejects_unknown(conn):
    m.create_user(conn, "a")
    with pytest.raises(ValueError):
        m.set_fields(conn, "a", uuid="b")
    with pytest.raises(KeyError):
        m.set_fields(conn, "nobody", note="x")


def test_delete_user(conn):
    m.create_user(conn, "a")
    m.add_traffic(conn, "a", 1, 1)
    m.delete_user(conn, "a")
    assert m.get_user(conn, "a") is None
    assert conn.execute("SELECT COUNT(*) FROM traffic_log").fetchone()[0] == 0


def test_parse_and_fmt_size():
    assert m.parse_size("0") == 0
    assert m.parse_size("100G") == 100 * 1024 ** 3
    assert m.parse_size("1.5T") == int(1.5 * 1024 ** 4)
    assert m.parse_size("500MB") == 500 * 1024 ** 2
    assert m.fmt_size(1536) == "1.5 KB"
    assert m.fmt_size(0) == "0 B"


def test_upsert_node_idempotent(conn):
    m.upsert_node(conn, **node_dict())
    m.upsert_node(conn, **node_dict() | {"host": "5.6.7.8"})
    nodes = m.list_nodes(conn, enabled_only=False)
    assert len(nodes) == 1 and nodes[0]["host"] == "5.6.7.8"
    m.set_node_enabled(conn, "PH-宿舍", False)
    assert m.list_nodes(conn) == []
    with pytest.raises(ValueError):
        m.upsert_node(conn, name="x", host="h")
