import json

import pytest

from phice.protocol import (Bye, Hello, Ping, ProtocolError, SensorPacket, parse_client_message,
                            state_message)


def packet(**over):
    d = {"t": "s", "seq": 1, "ts": 1.5, "o": [10, 20, 30], "rr": [1, 2, 3], "g": [0, 0, 9.8],
         "b": {"left": 1, "right": 0}, "c": {"left": 3, "right": 0}, "sd": -4.5}
    d.update(over)
    return json.dumps(d)


def test_parses_sensor_packet():
    p = parse_client_message(packet())
    assert isinstance(p, SensorPacket)
    assert (p.alpha, p.beta, p.gamma) == (10, 20, 30)
    assert p.buttons == {"left": True, "right": False}
    assert p.counters == {"left": 3, "right": 0}
    assert p.scroll_delta == -4.5
    assert p.rate_dps == pytest.approx((1 + 4 + 9) ** 0.5)


def test_orientation_may_be_null_before_first_event():
    p = parse_client_message(packet(o=None))
    assert not p.has_orientation
    p = parse_client_message(packet(o=[None, None, None]))
    assert not p.has_orientation


@pytest.mark.parametrize("over", [
    {"o": [400, 0, 0]}, {"o": [0, 200, 0]}, {"o": [0, 0, 95]}, {"o": [1, 2]},
    {"rr": [6000, 0, 0]}, {"g": [0, 0, 60]}, {"sd": 20000}, {"seq": 0}, {"seq": "1"},
    {"b": {"Left": 1}}, {"b": {"left": 2}}, {"c": {"left": -1}}, {"c": {"left": 1.5}},
    {"ts": "now"}, {"t": "zzz"},
])
def test_rejects_out_of_range(over):
    with pytest.raises(ProtocolError):
        parse_client_message(packet(**over))


def test_rejects_too_many_buttons():
    b = {f"b{i}": 0 for i in range(17)}
    with pytest.raises(ProtocolError):
        parse_client_message(packet(b=b))


def test_rejects_large_frames_and_bad_json():
    with pytest.raises(ProtocolError):
        parse_client_message("x" * 3000)
    with pytest.raises(ProtocolError):
        parse_client_message("{not json")
    with pytest.raises(ProtocolError):
        parse_client_message("[1,2]")


def test_hello_ping_bye():
    h = parse_client_message(json.dumps({"t": "hello", "ver": 1, "pair": "abcdefghij", "name": "iPhone"}))
    assert isinstance(h, Hello) and h.pair == "abcdefghij" and h.token is None
    with pytest.raises(ProtocolError):
        parse_client_message(json.dumps({"t": "hello", "ver": 2}))
    with pytest.raises(ProtocolError):
        parse_client_message(json.dumps({"t": "hello", "ver": 1, "token": "bad token!"}))
    assert isinstance(parse_client_message('{"t":"ping"}'), Ping)
    assert isinstance(parse_client_message('{"t":"bye"}'), Bye)


def test_state_message_shape():
    d = json.loads(state_message(conn=True, power=False, phase="off", recenter=0.12345, idle_hz=0,
                                 accessibility=True, ui={"haptics": True}))
    assert d["t"] == "state" and d["recenter"] == 0.123 and d["ui"] == {"haptics": True}
