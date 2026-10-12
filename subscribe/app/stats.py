"""sing-box v2ray_api 流量统计客户端。

只用到 StatsService/QueryStats 一个方法、两条消息，手工编解码 protobuf，不生成代码。
线上格式（与 v2ray-core 一致）：
  QueryStatsRequest  { string pattern = 1; bool reset = 2; }
  QueryStatsResponse { repeated Stat stat = 1; }   Stat { string name = 1; int64 value = 2; }
统计项名字形如 user>>>alice>>>traffic>>>uplink。
"""
from .config import STATS_ADDR

METHOD = "/v2ray.core.app.stats.command.StatsService/QueryStats"


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _read_varint(buf: bytes, i: int):
    shift, val = 0, 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def encode_query(pattern: str, reset: bool) -> bytes:
    p = pattern.encode()
    out = b"\x0a" + _varint(len(p)) + p
    if reset:
        out += b"\x10\x01"
    return out


def _fields(buf: bytes):
    """逐个产出 (field_no, value)：wire type 0 → int，2 → bytes；其他类型跳过。"""
    i = 0
    while i < len(buf):
        key, i = _read_varint(buf, i)
        field, wtype = key >> 3, key & 7
        if wtype == 0:
            val, i = _read_varint(buf, i)
            yield field, val
        elif wtype == 2:
            ln, i = _read_varint(buf, i)
            yield field, buf[i:i + ln]
            i += ln
        elif wtype == 1:
            i += 8
        elif wtype == 5:
            i += 4
        else:
            raise ValueError(f"unsupported wire type {wtype}")


def decode_stats(buf: bytes) -> dict:
    """QueryStatsResponse → {name: value}"""
    out = {}
    for field, val in _fields(buf):
        if field != 1:
            continue
        name, value = "", 0
        for f, v in _fields(val):
            if f == 1:
                name = v.decode()
            elif f == 2:
                value = v - (1 << 64) if v >= (1 << 63) else v
        out[name] = value
    return out


def user_traffic_from_stats(stats: dict) -> dict:
    """{'user>>>alice>>>traffic>>>uplink': 1, ...} → {'alice': (up, down)}"""
    users = {}
    for name, value in stats.items():
        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "user" and parts[2] == "traffic":
            up, down = users.get(parts[1], (0, 0))
            if parts[3] == "uplink":
                up += value
            elif parts[3] == "downlink":
                down += value
            users[parts[1]] = (up, down)
    return users


def query_user_traffic(addr: str = STATS_ADDR, reset: bool = True, timeout: float = 5.0) -> dict:
    """向 sing-box 查询并（默认）清零各用户计数，返回 {name: (up, down)}。失败抛异常。"""
    import grpc  # 延迟导入：测试与 CLI 不需要

    with grpc.insecure_channel(addr) as channel:
        call = channel.unary_unary(METHOD, request_serializer=lambda b: b, response_deserializer=lambda b: b)
        raw = call(encode_query("user>>>", reset), timeout=timeout)
    return user_traffic_from_stats(decode_stats(raw))
