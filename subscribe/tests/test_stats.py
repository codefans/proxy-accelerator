from app.stats import METHOD, _varint, decode_stats, encode_query, user_traffic_from_stats


def test_method_path_is_singbox_package():
    # sing-box experimental/v2rayapi/stats.proto: package experimental.v2rayapi; service StatsService
    assert METHOD == "/experimental.v2rayapi.StatsService/QueryStats"


def _stat(name: str, value: int) -> bytes:
    n = name.encode()
    body = b"\x0a" + _varint(len(n)) + n + b"\x10" + _varint(value)
    return b"\x0a" + _varint(len(body)) + body


def test_encode_query():
    assert encode_query("user>>>", True) == b"\x0a\x07user>>>\x10\x01"
    assert encode_query("user>>>", False) == b"\x0a\x07user>>>"


def test_varint_multibyte():
    assert _varint(300) == b"\xac\x02"
    assert _varint(0) == b"\x00"


def test_decode_and_group():
    raw = (_stat("user>>>alice>>>traffic>>>uplink", 300)
           + _stat("user>>>alice>>>traffic>>>downlink", 2 ** 40)
           + _stat("user>>>bob>>>traffic>>>downlink", 7)
           + _stat("inbound>>>hy2-ph>>>traffic>>>uplink", 999))
    stats = decode_stats(raw)
    assert stats["user>>>alice>>>traffic>>>downlink"] == 2 ** 40
    assert user_traffic_from_stats(stats) == {"alice": (300, 2 ** 40), "bob": (0, 7)}


def test_decode_skips_unknown_fields():
    # field 2 varint（未知）+ 正常 stat
    raw = b"\x10\x05" + _stat("user>>>x>>>traffic>>>uplink", 1)
    assert decode_stats(raw) == {"user>>>x>>>traffic>>>uplink": 1}
