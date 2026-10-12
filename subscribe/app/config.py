"""运行参数，全部可用环境变量覆盖（容器里由 compose 传入）。"""
import os
from pathlib import Path

DB_PATH = os.environ.get("PA_DB", "/etc/proxy-accelerator/subscribe.db")
SINGBOX_CONF = os.environ.get("PA_SINGBOX_CONF", "/etc/sing-box/config.json")
SINGBOX_BIN = os.environ.get("PA_SINGBOX_BIN", "sing-box")
RELAY_ENV = os.environ.get("PA_RELAY_ENV", "/etc/proxy-accelerator/relay.env")
M1_USERS_DIR = os.environ.get("PA_M1_USERS_DIR", "/etc/proxy-accelerator/users")
STATS_ADDR = os.environ.get("PA_STATS_ADDR", "127.0.0.1:10085")
# 监听所有网卡：Caddy 走 127.0.0.1，宿舍节点经 WireGuard 走 10.9.0.1 拉 /internal/node；
# 公网 8000 由 nftables 挡住（relay/nftables.conf.template 没放行）
API_HOST = os.environ.get("PA_API_HOST", "0.0.0.0")
API_PORT = int(os.environ.get("PA_API_PORT", "8000"))
SUB_DOMAIN = os.environ.get("PA_SUB_DOMAIN", "")
SUB_PORT = int(os.environ.get("PA_SUB_PORT", "2053"))
SYNC_INTERVAL = int(os.environ.get("PA_SYNC_INTERVAL", "60"))
SUB_FILENAME = "ph-dorm.yaml"
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates"
RESET_TZ = "Asia/Shanghai"  # 月初流量归零、每日备份时刻按北京时间（与马尼拉同为 UTC+8）

# M3：告警与备份
WG_IFACE = os.environ.get("PA_WG_IFACE", "wg0")
HANDSHAKE_MAX_AGE = int(os.environ.get("PA_HANDSHAKE_MAX_AGE", "180"))
TG_BOT_TOKEN = os.environ.get("PA_TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("PA_TG_CHAT_ID", "")
TRAFFIC_WARN_BYTES = int(float(os.environ.get("PA_TRAFFIC_WARN_GB", "20")) * 1024 ** 3)  # 单用户 24h 流量告警线
BACKUP_DIR = os.environ.get("PA_BACKUP_DIR", "/etc/proxy-accelerator/backups")
BACKUP_HOUR = int(os.environ.get("PA_BACKUP_HOUR", "4"))
BACKUP_KEEP = int(os.environ.get("PA_BACKUP_KEEP", "14"))
BACKUP_TO_TELEGRAM = os.environ.get("PA_BACKUP_TO_TELEGRAM", "0") == "1"
