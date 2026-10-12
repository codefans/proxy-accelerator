import sqlite3
import tarfile
from datetime import datetime, timedelta, timezone

from app import models as m
from app.backup import make_backup, maybe_daily_backup


def test_make_backup_contents_and_prune(conn, tmp_path):
    m.create_user(conn, "alice")
    env = tmp_path / "relay.env"
    env.write_text("HOST=x\n")
    dest = tmp_path / "backups"
    t0 = datetime(2026, 10, 10, 4, 0, tzinfo=timezone.utc)
    paths = [make_backup(conn, dest=str(dest), env_path=str(env), keep=2, now=t0 + timedelta(days=i)) for i in range(3)]
    assert not paths[0].exists() and paths[1].exists() and paths[2].exists()
    with tarfile.open(paths[2]) as tar:
        assert sorted(tar.getnames()) == ["relay.env", "subscribe.db"]
        tar.extract("subscribe.db", tmp_path / "x")
    restored = sqlite3.connect(tmp_path / "x" / "subscribe.db")
    assert restored.execute("SELECT name FROM users").fetchone()[0] == "alice"
    assert not (dest / ".snapshot.db").exists()


def test_maybe_daily_backup_once_per_day(conn, tmp_path, monkeypatch):
    monkeypatch.setattr("app.backup.BACKUP_DIR", str(tmp_path / "b"))
    monkeypatch.setattr("app.backup.RELAY_ENV", str(tmp_path / "none.env"))
    # 北京时间 04:xx = UTC 20:xx 前一天
    at4 = datetime(2026, 10, 9, 20, 30, tzinfo=timezone.utc)
    assert maybe_daily_backup(conn, now=at4 - timedelta(hours=1), hour=4, to_telegram=False) is None
    p = maybe_daily_backup(conn, now=at4, hour=4, to_telegram=False)
    assert p is not None and p.exists()
    assert maybe_daily_backup(conn, now=at4 + timedelta(minutes=10), hour=4, to_telegram=False) is None
    assert m.meta_get(conn, "last_backup") == "2026-10-10"
    assert maybe_daily_backup(conn, now=at4 + timedelta(days=1), hour=4, to_telegram=False) is not None
