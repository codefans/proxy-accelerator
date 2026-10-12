"""Telegram 通知：只用 Bot API 的 sendMessage / sendDocument，标准库实现。未配置时只写日志。"""
import json
import logging
import mimetypes
import urllib.request
import uuid
from pathlib import Path

from .config import TG_BOT_TOKEN, TG_CHAT_ID

log = logging.getLogger("pa.notify")


def configured() -> bool:
    return bool(TG_BOT_TOKEN and TG_CHAT_ID)


def _api(method: str, data: bytes, content_type: str, timeout: float = 15.0) -> bool:
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/{method}"
    req = urllib.request.Request(url, data=data, headers={"Content-Type": content_type}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r).get("ok", False)


def telegram_send(text: str) -> bool:
    if not configured():
        log.info("[通知未配置] %s", text)
        return False
    try:
        return _api("sendMessage", json.dumps({"chat_id": TG_CHAT_ID, "text": text}).encode(), "application/json")
    except Exception as e:  # noqa: BLE001
        log.warning("Telegram 发送失败: %s", e)
        return False


def telegram_send_document(path: str, caption: str = "") -> bool:
    if not configured():
        log.info("[通知未配置] 文件 %s", path)
        return False
    p = Path(path)
    boundary = uuid.uuid4().hex
    ctype = mimetypes.guess_type(p.name)[0] or "application/octet-stream"
    body = b""
    for k, v in (("chat_id", TG_CHAT_ID), ("caption", caption)):
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{p.name}\"\r\n"
             f"Content-Type: {ctype}\r\n\r\n").encode() + p.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    try:
        return _api("sendDocument", body, f"multipart/form-data; boundary={boundary}", timeout=60)
    except Exception as e:  # noqa: BLE001
        log.warning("Telegram 发文件失败: %s", e)
        return False
