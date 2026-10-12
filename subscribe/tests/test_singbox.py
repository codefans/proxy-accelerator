import json

import pytest

from app.singbox import write_users


def _users():
    hy2 = [{"name": "alice", "password": "p"}]
    vless = [{"name": "alice", "uuid": "u", "flow": "xtls-rprx-vision"}]
    return hy2, vless, ["alice"]


def test_write_users_updates_all_inbounds(singbox_conf):
    hy2, vless, names = _users()
    checked = []
    assert write_users(hy2, vless, names, conf_path=singbox_conf, check_fn=checked.append) is True
    assert checked == [singbox_conf + ".new"]
    conf = json.load(open(singbox_conf, encoding="utf-8"))
    for ib in conf["inbounds"]:
        assert ib["users"] == (hy2 if ib["type"] == "hysteria2" else vless), ib["tag"]
    assert conf["experimental"]["v2ray_api"]["stats"]["users"] == ["alice"]
    # 再写一次相同内容：无变化，不调用 check
    checked.clear()
    assert write_users(hy2, vless, names, conf_path=singbox_conf, check_fn=checked.append) is False
    assert checked == []


def test_write_users_check_failure_keeps_original(singbox_conf):
    before = open(singbox_conf, encoding="utf-8").read()

    def bad_check(_):
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        write_users(*_users(), conf_path=singbox_conf, check_fn=bad_check)
    assert open(singbox_conf, encoding="utf-8").read() == before


def test_write_users_empty_removes(singbox_conf):
    write_users(*_users(), conf_path=singbox_conf, check_fn=lambda p: None)
    assert write_users([], [], [], conf_path=singbox_conf, check_fn=lambda p: None) is True
    conf = json.load(open(singbox_conf, encoding="utf-8"))
    assert all(ib["users"] == [] for ib in conf["inbounds"])
