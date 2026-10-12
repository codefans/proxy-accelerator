from datetime import timedelta

import yaml

from app import models as m
from app.render import render_clash, singbox_users, userinfo_header


def _load(text):
    return yaml.safe_load(text)


def _check_refs(c):
    names = [p["name"] for p in c["proxies"]]
    groups = [g["name"] for g in c["proxy-groups"]]
    for g in c["proxy-groups"]:
        assert g["proxies"], g["name"]
        for p in g["proxies"]:
            assert p == "DIRECT" or p in names or p in groups, (g["name"], p)
    for r in c["rules"]:
        parts = r.split(",")
        tgt = parts[-2] if parts[-1] == "no-resolve" else parts[-1]
        assert tgt in ("DIRECT", "REJECT") or tgt in groups, r


def test_render_ok_user(conn, two_nodes):
    u = m.create_user(conn, "alice", hy2_password="12345678901234567890123456789012")
    c = _load(render_clash(u, two_nodes))
    assert [p["name"] for p in c["proxies"]] == ["PH-宿舍 hy2", "PH-宿舍 reality", "HK-中转 hy2", "HK-中转 reality"]
    _check_refs(c)
    ph, hk = c["proxies"][0], c["proxies"][2]
    assert ph["ports"] == "20000-30000" and "ports" not in hk
    assert isinstance(ph["password"], str) and ph["password"] == u["hy2_password"]
    assert c["proxies"][1]["reality-opts"]["short-id"] == "1234567890123456"
    assert c["proxies"][1]["uuid"] == u["uuid"]
    assert c["proxy-groups"][1]["type"] == "fallback"
    assert c["proxy-groups"][1]["proxies"][:2] == ["PH-宿舍 hy2", "PH-宿舍 reality"]
    assert c["proxy-groups"][2]["name"] == "🤖 AI 服务"
    assert c["rules"][0].startswith("GEOSITE,category-ai-chat-!cn")


def test_render_hk_first_in_db_still_ph_first(conn, two_nodes):
    conn.execute("UPDATE nodes SET sort=-5 WHERE name='HK-中转'")
    conn.commit()
    u = m.create_user(conn, "a")
    c = _load(render_clash(u, m.list_nodes(conn)))
    assert c["proxies"][0]["name"] == "PH-宿舍 hy2"


def test_render_without_ph_node(conn, two_nodes):
    m.set_node_enabled(conn, "PH-宿舍", False)
    u = m.create_user(conn, "a")
    c = _load(render_clash(u, m.list_nodes(conn)))
    _check_refs(c)
    assert len(c["proxies"]) == 2 and len(c["proxy-groups"]) == 2
    assert not any("AI" in r for r in c["rules"])


def test_render_expired_user(conn, two_nodes):
    u = m.create_user(conn, "a", days=1)
    m.set_fields(conn, "a", expire_at=m.iso(m.utcnow() - timedelta(days=1)))
    text = render_clash(m.get_user(conn, "a"), two_nodes)
    assert "订阅已到期" in text
    c = _load(text)
    assert c["proxies"] == [] and c["rules"] == ["MATCH,DIRECT"]
    _check_refs(c)


def test_userinfo_header(conn):
    u = m.create_user(conn, "a", quota_bytes=1000, days=1)
    m.add_traffic(conn, "a", 10, 20)
    h = userinfo_header(m.get_user(conn, "a"))
    assert h.startswith("upload=10; download=20; total=1000; expire=")
    u2 = m.create_user(conn, "b")
    assert userinfo_header(u2) == "upload=0; download=0"


def test_singbox_users_sorted(conn):
    m.create_user(conn, "zed")
    m.create_user(conn, "amy")
    hy2, vless, names = singbox_users(m.list_users(conn))
    assert names == ["amy", "zed"]
    assert hy2[0]["name"] == "amy" and set(hy2[0]) == {"name", "password"}
    assert vless[0]["flow"] == "xtls-rprx-vision" and set(vless[0]) == {"name", "uuid", "flow"}
