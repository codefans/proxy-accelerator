"""用户与节点管理 CLI（容器内 `pa ...`，宿主机由 relay/install.sh 装的 /usr/local/bin/pa 转发）。"""
import argparse
import json
import sys
import urllib.request
from pathlib import Path

from . import models as m
from .config import API_PORT, M1_USERS_DIR, RELAY_ENV, SUB_DOMAIN, SUB_PORT
from .models import read_env_file
from .render import render_clash

API_HOST = "127.0.0.1"  # CLI 永远走本机


def trigger_sync():
    """让服务立刻同步到 sing-box；服务没起来就等定时任务。"""
    try:
        req = urllib.request.Request(f"http://{API_HOST}:{API_PORT}/internal/sync", method="POST")
        with urllib.request.urlopen(req, timeout=20) as r:
            res = json.load(r)
        print("已同步到 sing-box" + ("（已重启）" if res.get("changed") else "（无变化）"))
    except Exception as e:  # noqa: BLE001
        print(f"未能立即同步（{e}），60 秒内自动生效")


def sub_url(conn, user) -> str:
    if SUB_DOMAIN:
        return f"https://{SUB_DOMAIN}/sub/{user['token']}"
    host = read_env_file(RELAY_ENV).get("HOST", "<relay-ip>") if Path(RELAY_ENV).exists() else "<relay-ip>"
    return f"https://{host}:{SUB_PORT}/sub/{user['token']}   (未配置 SUB_DOMAIN，自签证书；可改用 pa clash 导出)"


def print_user(conn, u):
    st = m.user_status(u)
    used = u["used_up"] + u["used_down"]
    quota = m.fmt_size(u["quota_bytes"]) if u["quota_bytes"] else "不限"
    print(f"{u['name']:<12} {st:<10} 已用 {m.fmt_size(used):>10} / {quota:<8} 到期 {u['expire_at'] or '永久':<25} {u['note']}")


# ---------- 子命令 ----------
def cmd_adduser(conn, a):
    if m.get_user(conn, a.name):
        sys.exit(f"用户 {a.name} 已存在")
    u = m.create_user(conn, a.name, quota_bytes=m.parse_size(a.quota), days=a.days, note=a.note)
    print_user(conn, u)
    print("订阅地址:", sub_url(conn, u))
    trigger_sync()


def cmd_del(conn, a):
    m.delete_user(conn, a.name)
    print(f"已删除 {a.name}")
    trigger_sync()


def cmd_renew(conn, a):
    m.extend_expiry(conn, a.name, a.days)
    print_user(conn, m.get_user(conn, a.name))
    trigger_sync()


def cmd_quota(conn, a):
    m.set_fields(conn, a.name, quota_bytes=m.parse_size(a.size))
    print_user(conn, m.get_user(conn, a.name))
    trigger_sync()


def cmd_enable(conn, a):
    m.set_fields(conn, a.name, enabled=1 if a.cmd == "enable" else 0)
    print_user(conn, m.get_user(conn, a.name))
    trigger_sync()


def cmd_reset_token(conn, a):
    m.set_fields(conn, a.name, token=m.new_token())
    print("新订阅地址:", sub_url(conn, m.get_user(conn, a.name)))


def cmd_reset_usage(conn, a):
    m.set_fields(conn, a.name, used_up=0, used_down=0)
    print_user(conn, m.get_user(conn, a.name))
    trigger_sync()


def cmd_list(conn, a):
    for u in m.list_users(conn):
        print_user(conn, u)


def cmd_stats(conn, a):
    users = [m.get_user(conn, a.name)] if a.name else m.list_users(conn)
    for u in users:
        if not u:
            sys.exit(f"用户 {a.name} 不存在")
        up7, down7 = m.traffic_since(conn, u["name"], 7)
        print(f"{u['name']:<12} 本月 ↑{m.fmt_size(u['used_up'])} ↓{m.fmt_size(u['used_down'])}   "
              f"近 7 天 ↑{m.fmt_size(up7)} ↓{m.fmt_size(down7)}")


def cmd_url(conn, a):
    u = m.get_user(conn, a.name) or sys.exit(f"用户 {a.name} 不存在")
    print(sub_url(conn, u))


def cmd_clash(conn, a):
    u = m.get_user(conn, a.name) or sys.exit(f"用户 {a.name} 不存在")
    yaml = render_clash(u, m.list_nodes(conn))
    if a.out:
        Path(a.out).write_text(yaml, encoding="utf-8")
        print(f"已写入 {a.out}")
    else:
        print(yaml)


def cmd_nodes(conn, a):
    if a.action == "list":
        for n in m.list_nodes(conn, enabled_only=False):
            print(f"{n['name']:<12} {'on ' if n['enabled'] else 'off'} {n['host']}  hy2:{n['hy2_port']} "
                  f"{n['hy2_ports'] or ''}  reality:{n['vless_port']}  exit={n['exit']}  ↑{n['up_mbps']}/↓{n['down_mbps']}")
    elif a.action == "sync-env":
        e = read_env_file(a.env)
        common = dict(host=e["HOST"], reality_pubkey=e["REALITY_PUBLIC_KEY"], short_id=e["SHORT_ID"],
                      reality_sni=e["REALITY_SNI"], hy2_sni=e["SNI"], hy2_insecure=int(e["INSECURE"]),
                      up_mbps=int(e["UP_MBPS"]), down_mbps=int(e["DOWN_MBPS"]))
        m.upsert_node(conn, name="PH-宿舍", hy2_port=int(e["HY2_PH_PORT"]), hy2_ports=e.get("HOP_PORTS", ""),
                      vless_port=int(e["VLESS_PH_PORT"]), exit="ph", sort=0, **common)
        m.upsert_node(conn, name="HK-中转", hy2_port=int(e["HY2_HK_PORT"]), hy2_ports="",
                      vless_port=int(e["VLESS_HK_PORT"]), exit="hk", sort=10, **common)
        print(f"已从 {a.env} 同步 2 个节点")
    elif a.action == "add-standby":
        host = a.name or sys.exit("用法: pa nodes add-standby <备机IP或域名> [--suffix 备]")
        names = m.add_standby(conn, host, suffix=a.suffix)
        print(f"已添加备用节点: {', '.join(names) or '（没有主节点，先 pa nodes sync-env）'}")
    elif a.action == "add-v6":
        host = a.name or sys.exit("用法: pa nodes add-v6 <宿舍的 AAAA 域名，如 ph.example.com>")
        try:
            print(f"已添加 IPv6 直连节点: {m.add_v6_node(conn, host)}（宿舍侧需跑 node-ph/v6/install-v6.sh）")
        except KeyError:
            sys.exit("没有主节点 PH-宿舍，先 pa nodes sync-env")
    elif a.action == "del":
        m.delete_node(conn, a.name or sys.exit("用法: pa nodes del <name>"))
        print(f"已删除节点 {a.name}")
    else:
        m.set_node_enabled(conn, a.name, a.action == "enable")
        print(f"节点 {a.name} 已{'启用' if a.action == 'enable' else '停用'}")


def cmd_import_m1(conn, a):
    n = 0
    for f in sorted(Path(a.dir).glob("*.env")):
        name = f.stem
        if m.get_user(conn, name):
            continue
        e = read_env_file(str(f))
        m.create_user(conn, name, uuid=e["UUID"], hy2_password=e["HY2_PASSWORD"], note="M1 导入")
        n += 1
    print(f"导入 {n} 个 M1 用户")
    if n:
        trigger_sync()


def cmd_sync(conn, a):
    trigger_sync()


def cmd_backup(conn, a):
    from .backup import make_backup
    from .config import BACKUP_TO_TELEGRAM
    from .notify import telegram_send_document

    path = make_backup(conn)
    print(f"备份: {path}")
    if a.telegram or BACKUP_TO_TELEGRAM:
        print("已发到 Telegram" if telegram_send_document(str(path), "proxy-accelerator 手动备份") else "Telegram 发送失败/未配置")


def cmd_alert(conn, a):
    from .notify import configured, telegram_send

    if not configured():
        sys.exit("未配置 Telegram：relay/install.sh 加 TG_BOT_TOKEN=... TG_CHAT_ID=... 重跑")
    print("已发送" if telegram_send("🔔 proxy-accelerator 测试消息") else "发送失败，检查 token / chat_id")


def build_parser():
    p = argparse.ArgumentParser(prog="pa", description="proxy-accelerator 用户/节点管理")
    s = p.add_subparsers(dest="cmd", required=True)

    x = s.add_parser("adduser", help="新增用户"); x.add_argument("name")
    x.add_argument("--quota", default="0", help="月流量，如 100G；0 不限"); x.add_argument("--days", type=int, default=None, help="有效天数，不填永久")
    x.add_argument("--note", default=""); x.set_defaults(fn=cmd_adduser)
    x = s.add_parser("del", help="删除用户"); x.add_argument("name"); x.set_defaults(fn=cmd_del)
    x = s.add_parser("renew", help="续期"); x.add_argument("name"); x.add_argument("--days", type=int, required=True); x.set_defaults(fn=cmd_renew)
    x = s.add_parser("quota", help="改月配额"); x.add_argument("name"); x.add_argument("size"); x.set_defaults(fn=cmd_quota)
    for c in ("enable", "disable"):
        x = s.add_parser(c); x.add_argument("name"); x.set_defaults(fn=cmd_enable)
    x = s.add_parser("reset-token", help="重置订阅地址"); x.add_argument("name"); x.set_defaults(fn=cmd_reset_token)
    x = s.add_parser("reset-usage", help="本月流量清零"); x.add_argument("name"); x.set_defaults(fn=cmd_reset_usage)
    s.add_parser("list").set_defaults(fn=cmd_list)
    x = s.add_parser("stats"); x.add_argument("name", nargs="?"); x.set_defaults(fn=cmd_stats)
    x = s.add_parser("url", help="打印订阅地址"); x.add_argument("name"); x.set_defaults(fn=cmd_url)
    x = s.add_parser("clash", help="导出 Clash YAML"); x.add_argument("name"); x.add_argument("--out"); x.set_defaults(fn=cmd_clash)
    x = s.add_parser("nodes", help="节点表：list | sync-env | add-standby <host> | add-v6 <host> | del <name> | enable/disable <name>")
    x.add_argument("action", choices=["list", "sync-env", "add-standby", "add-v6", "del", "enable", "disable"])
    x.add_argument("name", nargs="?", help="节点名；add-standby 时为备机 IP/域名；add-v6 时为宿舍 AAAA 域名")
    x.add_argument("--env", default=RELAY_ENV); x.add_argument("--suffix", default="备"); x.set_defaults(fn=cmd_nodes)
    x = s.add_parser("import-m1", help="导入 relay/user.sh 创建的用户"); x.add_argument("--dir", default=M1_USERS_DIR); x.set_defaults(fn=cmd_import_m1)
    s.add_parser("sync", help="立即同步到 sing-box").set_defaults(fn=cmd_sync)
    x = s.add_parser("backup", help="立即备份 relay.env + subscribe.db"); x.add_argument("--telegram", action="store_true"); x.set_defaults(fn=cmd_backup)
    x = s.add_parser("alert", help="发一条 Telegram 测试消息"); x.add_argument("action", choices=["test"]); x.set_defaults(fn=cmd_alert)
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    conn = m.connect()
    try:
        a.fn(conn, a)
    except KeyError as e:
        sys.exit(f"用户/节点不存在: {e}")


if __name__ == "__main__":
    main()
