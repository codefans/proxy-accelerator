import asyncio
from datetime import timedelta

import pytest
import yaml
from fastapi.testclient import TestClient

from app import main
from app import models as m
from app.render import render_clash


def test_add_v6_node_copies_ph_and_sorts_first(conn, two_nodes):
    name = m.add_v6_node(conn, "ph.example.com")
    assert name == "PH-直连 IPv6"
    nodes = m.list_nodes(conn)
    assert [n["name"] for n in nodes][0] == "PH-直连 IPv6"
    v6, ph = m.get_node(conn, "PH-直连 IPv6"), m.get_node(conn, "PH-宿舍")
    assert v6["host"] == "ph.example.com" and v6["exit"] == "ph-v6" and v6["hy2_insecure"] == 1
    for k in ("hy2_port", "hy2_ports", "vless_port", "reality_pubkey", "short_id", "reality_sni"):
        assert v6[k] == ph[k]
    with pytest.raises(KeyError):
        m.add_v6_node(conn, "x", base="nope")


def test_render_puts_v6_first_and_in_ai_group(conn, two_nodes):
    m.add_v6_node(conn, "ph.example.com")
    u = m.create_user(conn, "a")
    c = yaml.safe_load(render_clash(u, m.list_nodes(conn)))
    names = [p["name"] for p in c["proxies"]]
    assert names[:4] == ["PH-直连 IPv6 hy2", "PH-直连 IPv6 reality", "PH-宿舍 hy2", "PH-宿舍 reality"]
    ai = [g for g in c["proxy-groups"] if g["name"] == "🤖 AI 服务"][0]
    assert ai["proxies"][0] == "PH-直连 IPv6 hy2"
    assert c["proxies"][0]["skip-cert-verify"] is True


def test_internal_node_endpoint(conn, two_nodes, tmp_path, monkeypatch):
    env = tmp_path / "relay.env"
    env.write_text("REALITY_PRIVATE_KEY=priv\nSHORT_ID=0123\nREALITY_SNI=www.microsoft.com\nSNI=www.bing.com\n"
                   "HY2_PH_PORT=443\nVLESS_PH_PORT=443\nHOP_PORTS=20000-30000\nUP_MBPS=40\nDOWN_MBPS=40\nSECRET=no\n")
    monkeypatch.setattr(main, "RELAY_ENV", str(env))
    path = conn.execute("PRAGMA database_list").fetchone()[2]
    monkeypatch.setattr(main, "connect", lambda: m.connect(path))
    main.state.update(conn=conn, lock=asyncio.Lock())
    m.create_user(conn, "alice")
    m.create_user(conn, "old", days=1)
    m.set_fields(conn, "old", expire_at=m.iso(m.utcnow() - timedelta(days=1)))
    m.add_v6_node(conn, "ph.example.com")
    r = TestClient(main.app).get("/internal/node")
    assert r.status_code == 200
    body = r.json()
    assert body["v6_host"] == "ph.example.com"
    assert [u["name"] for u in body["users"]] == ["alice"]           # 到期用户不下发
    assert set(body["users"][0]) == {"name", "uuid", "hy2_password"}
    assert body["params"]["REALITY_PRIVATE_KEY"] == "priv" and "SECRET" not in body["params"]
    assert body["params"]["REALITY_PUBLIC_KEY"] == ""                   # 缺的键给空串，不报错
