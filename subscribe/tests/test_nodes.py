import pytest
import yaml

from app import models as m
from app.render import render_clash


def test_add_standby_copies_primaries(conn, two_nodes):
    names = m.add_standby(conn, "9.9.9.9")
    assert names == ["PH-宿舍·备", "HK-中转·备"]
    nodes = {n["name"]: n for n in m.list_nodes(conn)}
    ph, phb = nodes["PH-宿舍"], nodes["PH-宿舍·备"]
    assert phb["host"] == "9.9.9.9" and phb["sort"] == ph["sort"] + 1
    for k in ("hy2_port", "hy2_ports", "vless_port", "reality_pubkey", "short_id", "exit"):
        assert phb[k] == ph[k]
    # 再执行一次是更新而不是重复
    m.add_standby(conn, "8.8.8.8")
    assert len(m.list_nodes(conn)) == 4 and m.get_node(conn, "HK-中转·备")["host"] == "8.8.8.8"


def test_add_standby_without_primaries(conn):
    assert m.add_standby(conn, "9.9.9.9") == []


def test_render_orders_primary_then_standby_within_exit(conn, two_nodes):
    m.add_standby(conn, "9.9.9.9")
    u = m.create_user(conn, "a")
    c = yaml.safe_load(render_clash(u, m.list_nodes(conn)))
    assert [p["name"] for p in c["proxies"]] == [
        "PH-宿舍 hy2", "PH-宿舍 reality", "PH-宿舍·备 hy2", "PH-宿舍·备 reality",
        "HK-中转 hy2", "HK-中转 reality", "HK-中转·备 hy2", "HK-中转·备 reality",
    ]
    assert c["proxy-groups"][1]["proxies"][2] == "PH-宿舍·备 hy2"
    ai = [g for g in c["proxy-groups"] if g["name"] == "🤖 AI 服务"][0]
    assert "HK-中转·备 hy2" not in ai["proxies"] and "PH-宿舍·备 hy2" in ai["proxies"]


def test_delete_node(conn, two_nodes):
    m.delete_node(conn, "HK-中转")
    assert [n["name"] for n in m.list_nodes(conn)] == ["PH-宿舍"]
    with pytest.raises(KeyError):
        m.delete_node(conn, "nope")
