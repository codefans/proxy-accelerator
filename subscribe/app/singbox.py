"""sing-box 子进程看护 + 配置里 users[] 的写入。"""
import asyncio
import json
import logging
import os
import subprocess

from .config import SINGBOX_BIN, SINGBOX_CONF

log = logging.getLogger("pa.singbox")


def check(path: str, binary: str = SINGBOX_BIN) -> None:
    r = subprocess.run([binary, "check", "-c", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip())


def write_users(hy2_users, vless_users, names, conf_path: str = SINGBOX_CONF, check_fn=check) -> bool:
    """把有效用户写进所有 hysteria2/vless 入站与 v2ray_api 统计列表。无变化返回 False。"""
    with open(conf_path, encoding="utf-8") as f:
        conf = json.load(f)
    desired = {"hysteria2": hy2_users, "vless": vless_users}
    changed = False
    for ib in conf.get("inbounds", []):
        want = desired.get(ib.get("type"))
        if want is not None and ib.get("users") != want:
            ib["users"] = want
            changed = True
    stats = conf.setdefault("experimental", {}).setdefault("v2ray_api", {}).setdefault("stats", {})
    if stats.get("users") != names:
        stats["users"] = names
        changed = True
    if not changed:
        return False
    tmp = conf_path + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=2, ensure_ascii=False)
    check_fn(tmp)
    os.replace(tmp, conf_path)
    return True


class Supervisor:
    """以子进程方式运行 sing-box：意外退出 2 秒后拉起；restart() 用于配置变更。"""

    def __init__(self, binary: str = SINGBOX_BIN, conf: str = SINGBOX_CONF):
        self.binary, self.conf = binary, conf
        self.proc = None
        self._stopping = False
        self._watch_task = None  # 持有引用，防止任务被 GC

    @property
    def running(self) -> bool:
        return self.proc is not None and self.proc.returncode is None

    async def start(self):
        self._stopping = False
        self.proc = await asyncio.create_subprocess_exec(self.binary, "run", "-c", self.conf)
        log.info("sing-box 已启动 pid=%s", self.proc.pid)
        self._watch_task = asyncio.create_task(self._watch(self.proc))

    async def _watch(self, proc):
        rc = await proc.wait()
        if self._stopping or proc is not self.proc:
            return
        log.error("sing-box 意外退出 rc=%s，2 秒后重启", rc)
        await asyncio.sleep(2)
        if not self._stopping:
            await self.start()

    async def stop(self):
        self._stopping = True
        p = self.proc
        if p and p.returncode is None:
            p.terminate()
            try:
                await asyncio.wait_for(p.wait(), 10)
            except asyncio.TimeoutError:
                p.kill()
                await p.wait()

    async def restart(self):
        log.info("重启 sing-box 以应用用户变更")
        await self.stop()
        await self.start()
