"""备份：relay.env + subscribe.db 打成 tar.gz，保留最近 N 份；可选发到 Telegram。

这两个文件足以在新 VPS 上 `relay/install.sh --restore <tar.gz>` 原样重建。
"""
import logging
import sqlite3
import tarfile
from pathlib import Path
from zoneinfo import ZoneInfo

from .config import BACKUP_DIR, BACKUP_HOUR, BACKUP_KEEP, BACKUP_TO_TELEGRAM, DB_PATH, RELAY_ENV, RESET_TZ
from .models import meta_get, meta_set, utcnow
from .notify import telegram_send_document

log = logging.getLogger("pa.backup")


def make_backup(conn=None, dest=None, env_path=None, db_path=None, keep: int = BACKUP_KEEP, now=None) -> Path:
    now = now or utcnow()
    dest = Path(dest or BACKUP_DIR)
    env_path = env_path or RELAY_ENV
    dest.mkdir(parents=True, exist_ok=True)
    out = dest / f"pa-backup-{now.astimezone(ZoneInfo(RESET_TZ)).strftime('%Y%m%d-%H%M')}.tar.gz"
    snapshot = dest / ".snapshot.db"
    src = conn or sqlite3.connect(db_path or DB_PATH)
    dst = sqlite3.connect(snapshot)
    try:
        src.backup(dst)  # 一致性快照，WAL 下也安全
    finally:
        dst.close()
        if conn is None:
            src.close()
    with tarfile.open(out, "w:gz") as tar:
        if Path(env_path).exists():
            tar.add(env_path, arcname="relay.env")
        tar.add(snapshot, arcname="subscribe.db")
    snapshot.unlink()
    for old in sorted(dest.glob("pa-backup-*.tar.gz"))[:-keep]:
        old.unlink()
    log.info("备份已写入 %s", out)
    return out


def maybe_daily_backup(conn, now=None, hour: int = BACKUP_HOUR, to_telegram: bool = BACKUP_TO_TELEGRAM):
    """到了备份时刻且今天还没备份 → 备份一次。返回文件路径或 None。"""
    now = now or utcnow()
    local = now.astimezone(ZoneInfo(RESET_TZ))
    if local.hour != hour:
        return None
    today = local.date().isoformat()
    if meta_get(conn, "last_backup") == today:
        return None
    path = make_backup(conn, now=now)
    meta_set(conn, "last_backup", today)
    if to_telegram:
        telegram_send_document(str(path), caption=f"proxy-accelerator 每日备份 {today}")
    return path
