import asyncio

import yaml
from fastapi.testclient import TestClient

from app import main
from app import models as m


class FakeSup:
    running = True

    async def restart(self):
        pass


def _client(conn, monkeypatch):
    # 接口每次请求开自己的连接：让它连到测试库
    path = conn.execute("PRAGMA database_list").fetchone()[2]
    monkeypatch.setattr(main, "connect", lambda: m.connect(path))
    main.state.update(conn=conn, sup=FakeSup(), lock=asyncio.Lock())
    return TestClient(main.app)  # 不进入 lifespan，不会拉起 sing-box


def test_healthz(conn, monkeypatch):
    assert _client(conn, monkeypatch).get("/healthz").json() == {"status": "ok", "singbox": True}


def test_sub_not_found(conn, monkeypatch):
    c = _client(conn, monkeypatch)
    assert c.get("/sub/notatoken").status_code == 404
    assert c.get("/sub/" + "0" * 32).status_code == 404


def test_sub_ok(conn, two_nodes, monkeypatch):
    u = m.create_user(conn, "alice", quota_bytes=10 * 1024 ** 3, days=30)
    r = _client(conn, monkeypatch).get(f"/sub/{u['token']}")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/yaml")
    assert r.headers["subscription-userinfo"].startswith("upload=0; download=0; total=10737418240; expire=")
    assert "ph-dorm.yaml" in r.headers["content-disposition"]
    c = yaml.safe_load(r.text)
    assert len(c["proxies"]) == 4
