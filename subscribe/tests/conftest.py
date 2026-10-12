import json
import re
from pathlib import Path

import pytest

from app import models

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "relay" / "sing-box" / "config.template.json"

PLACEHOLDERS = {
    "__HY2_PH_PORT__": "443", "__VLESS_PH_PORT__": "443", "__HY2_HK_PORT__": "8443", "__VLESS_HK_PORT__": "8443",
    "__UP_MBPS__": "50", "__DOWN_MBPS__": "50", "__SNI__": "www.bing.com", "__REALITY_SNI__": "www.microsoft.com",
    "__REALITY_PRIVATE_KEY__": "sEDWl52HNrbmKpgbyxfBwZLqIPJDQd2Ql3RbDVXpzGw", "__SHORT_ID__": "0123456789abcdef",
}


@pytest.fixture
def conn(tmp_path):
    c = models.connect(str(tmp_path / "t.db"))
    yield c
    c.close()


@pytest.fixture
def singbox_conf(tmp_path):
    """渲染 relay 的 sing-box 模板到临时文件，返回路径。"""
    text = TEMPLATE.read_text(encoding="utf-8")
    for k, v in PLACEHOLDERS.items():
        text = text.replace(k, v)
    assert not re.search(r"__[A-Z_]+__", text)
    json.loads(text)
    p = tmp_path / "config.json"
    p.write_text(text, encoding="utf-8")
    return str(p)


def node_dict(name="PH-宿舍", exit="ph", hy2_port=443, vless_port=443, hy2_ports="20000-30000", sort=0):
    return dict(name=name, host="1.2.3.4", hy2_port=hy2_port, hy2_ports=hy2_ports, vless_port=vless_port,
                reality_pubkey="DYivN-_LlIgW1KHqTCtE6VHmaTC6KdXUau9Snx6QIxY", short_id="1234567890123456",
                reality_sni="www.microsoft.com", hy2_sni="www.bing.com", hy2_insecure=1, up_mbps=50,
                down_mbps=50, exit=exit, enabled=1, sort=sort)


@pytest.fixture
def two_nodes(conn):
    models.upsert_node(conn, **node_dict())
    models.upsert_node(conn, **node_dict(name="HK-中转", exit="hk", hy2_port=8443, vless_port=8443, hy2_ports="", sort=10))
    return models.list_nodes(conn)
