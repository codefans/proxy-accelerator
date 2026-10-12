"""渲染：Clash YAML、subscription-userinfo 头、sing-box users[]。"""
import json
from datetime import timezone

from jinja2 import Environment, FileSystemLoader

from .config import TEMPLATES_DIR
from .models import parse_dt, user_status, utcnow

_env = Environment(loader=FileSystemLoader(str(TEMPLATES_DIR)), trim_blocks=True, lstrip_blocks=True,
                   autoescape=False, keep_trailing_newline=True)
# YAML 双引号标量 = JSON 字符串；全数字的密码/short-id 也不会被当成数字
_env.filters["q"] = lambda v: json.dumps(str(v), ensure_ascii=False)

STATUS_TEXT = {
    "disabled": "账号已停用，请联系管理员",
    "expired": "订阅已到期，请联系管理员续期",
    "over_quota": "本月流量已用完，下月 1 日自动恢复",
}


def order_nodes(nodes):
    nodes = [dict(n) for n in nodes]
    ph = [n for n in nodes if str(n["exit"]).startswith("ph")]
    return ph + [n for n in nodes if not str(n["exit"]).startswith("ph")]


def render_clash(user, nodes, now=None) -> str:
    now = now or utcnow()
    status = user_status(user, now)
    nodes = order_nodes(nodes) if status == "ok" else []
    return _env.get_template("clash.yaml.j2").render(
        user=dict(user),
        nodes=nodes,
        ph_nodes=[n for n in nodes if str(n["exit"]).startswith("ph")],
        reason=STATUS_TEXT.get(status, ""),
        generated_at=now.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
    )


def userinfo_header(user) -> str:
    parts = [f"upload={user['used_up']}", f"download={user['used_down']}"]
    if user["quota_bytes"]:
        parts.append(f"total={user['quota_bytes']}")
    exp = parse_dt(user["expire_at"])
    if exp:
        parts.append(f"expire={int(exp.timestamp())}")
    return "; ".join(parts)


def singbox_users(users):
    """→ (hysteria2 users, vless users, 统计用名字列表)，顺序稳定便于 diff。"""
    users = sorted(users, key=lambda u: u["name"])
    hy2 = [{"name": u["name"], "password": u["hy2_password"]} for u in users]
    vless = [{"name": u["name"], "uuid": u["uuid"], "flow": "xtls-rprx-vision"} for u in users]
    return hy2, vless, [u["name"] for u in users]
