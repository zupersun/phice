"""Wire protocol: JSON text frames between the phone page and the Mac.

Every inbound message is validated here (system boundary). Outbound messages
are built by the `*_message` helpers so the schema lives in one place.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from typing import Any

MAX_FRAME_BYTES = 2048
MAX_BUTTONS = 16
BUTTON_ID_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
PROTOCOL_VERSION = 1

Vec3 = tuple[float, float, float]


class ProtocolError(ValueError):
    """Raised for any malformed or out-of-range client message."""


@dataclass(frozen=True)
class Hello:
    """Who the phone is and what it can do. Pairing happened out of band, by
    code, before this channel existed; nothing here grants anything."""

    ver: int
    name: str
    caps: str = ""


@dataclass(frozen=True)
class ClientLog:
    """Something the page needs the Mac to know about itself.

    A phone showing a blank screen tells you nothing from the Mac side, and
    Safari's console is not reachable from here. This is the only channel
    through which the page can say what went wrong.
    """

    msg: str


@dataclass(frozen=True)
class Ping:
    pass


@dataclass(frozen=True)
class Bye:
    pass


@dataclass(frozen=True)
class SensorPacket:
    seq: int
    ts: float
    alpha: float | None
    beta: float | None
    gamma: float | None
    rr: Vec3
    g: Vec3
    buttons: dict[str, bool]
    counters: dict[str, int]
    scroll_delta: float
    #: Where the finger sits along the scroll strip, 0 (top) to 1 (bottom),
    #: or None when nothing is touching it. A delta cannot express a finger
    #: that is held still at the end of the track.
    scroll_pos: float | None = None
    hz: float = 0.0

    @property
    def rate_dps(self) -> float:
        return math.sqrt(sum(v * v for v in self.rr))

    @property
    def has_orientation(self) -> bool:
        return self.alpha is not None and self.beta is not None


def _num(v: Any, lo: float, hi: float, name: str, allow_none: bool = False) -> float | None:
    if v is None and allow_none:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise ProtocolError(f"{name}: not a number")
    f = float(v)
    if math.isnan(f) or f < lo or f > hi:
        raise ProtocolError(f"{name}: out of range")
    return f


def _vec3(v: Any, lim: float, name: str) -> Vec3:
    if not isinstance(v, list) or len(v) != 3:
        raise ProtocolError(f"{name}: expected 3 numbers")
    return tuple(_num(x if x is not None else 0.0, -lim, lim, name) for x in v)  # type: ignore[return-value]


def _button_map(v: Any, name: str, as_bool: bool) -> dict:
    if not isinstance(v, dict) or len(v) > MAX_BUTTONS:
        raise ProtocolError(f"{name}: expected object with <= {MAX_BUTTONS} keys")
    out = {}
    for k, val in v.items():
        if not isinstance(k, str) or not BUTTON_ID_RE.match(k):
            raise ProtocolError(f"{name}: bad button id")
        if as_bool:
            if val not in (0, 1, True, False):
                raise ProtocolError(f"{name}.{k}: expected 0/1")
            out[k] = bool(val)
        else:
            if isinstance(val, bool) or not isinstance(val, int) or val < 0 or val > 10**9:
                raise ProtocolError(f"{name}.{k}: expected non-negative int")
            out[k] = val
    return out


def parse_client_message(text: str) -> Hello | Ping | Bye | SensorPacket | ClientLog:
    if len(text.encode("utf-8", "replace")) > MAX_FRAME_BYTES:
        raise ProtocolError("frame too large")
    try:
        d = json.loads(text)
    except ValueError as e:
        raise ProtocolError(f"bad json: {e}") from e
    if not isinstance(d, dict):
        raise ProtocolError("expected object")
    t = d.get("t")
    if t == "s":
        o = d.get("o")
        if o is None:
            alpha = beta = gamma = None
        else:
            if not isinstance(o, list) or len(o) != 3:
                raise ProtocolError("o: expected 3 values")
            alpha = _num(o[0], 0.0, 360.0, "alpha", allow_none=True)
            beta = _num(o[1], -180.0, 180.0, "beta", allow_none=True)
            gamma = _num(o[2], -90.0, 90.0, "gamma", allow_none=True)
        seq = d.get("seq")
        if isinstance(seq, bool) or not isinstance(seq, int) or seq <= 0:
            raise ProtocolError("seq: expected positive int")
        return SensorPacket(
            seq=seq,
            ts=_num(d.get("ts"), 0.0, 1e9, "ts"),  # type: ignore[arg-type]
            alpha=alpha,
            beta=beta,
            gamma=gamma,
            rr=_vec3(d.get("rr", [0, 0, 0]), 5000.0, "rr"),
            g=_vec3(d.get("g", [0, 0, 0]), 50.0, "g"),
            buttons=_button_map(d.get("b", {}), "b", as_bool=True),
            counters=_button_map(d.get("c", {}), "c", as_bool=False),
            scroll_delta=_num(d.get("sd", 0.0), -10000.0, 10000.0, "sd"),  # type: ignore[arg-type]
            scroll_pos=_num(d.get("sp"), 0.0, 1.0, "sp", allow_none=True),
            hz=_num(d.get("hz", 0.0), 0.0, 1000.0, "hz"),  # type: ignore[arg-type]
        )
    if t == "hello":
        ver = d.get("ver")
        if ver != PROTOCOL_VERSION:
            raise ProtocolError("unsupported protocol version")
        name = d.get("name", "phone")
        if not isinstance(name, str):
            raise ProtocolError("name: expected string")
        caps = d.get("caps", "")
        if not isinstance(caps, str):
            raise ProtocolError("caps: expected string")
        return Hello(ver=ver, name=name[:64], caps=caps[:200])
    if t == "log":
        msg = d.get("msg", "")
        if not isinstance(msg, str):
            raise ProtocolError("msg: expected string")
        return ClientLog(msg=msg[:400])
    if t == "ping":
        return Ping()
    if t == "bye":
        return Bye()
    raise ProtocolError("unknown message type")


# --- server -> phone -------------------------------------------------------

def state_message(*, conn: bool, power: bool, phase: str, recenter: float, idle_hz: int,
                  accessibility: bool, ui: dict) -> str:
    return json.dumps({"t": "state", "conn": conn, "power": power, "phase": phase,
                       "recenter": round(recenter, 3), "idle_hz": idle_hz,
                       "accessibility": accessibility, "ui": ui})


def layout_message(layout_dict: dict) -> str:
    return json.dumps({"t": "layout", **layout_dict})


#: Sent in pieces this size, and the size is the whole point. Measured against a
#: real iPhone: the 394-byte layout message always arrived, an 11855-byte theme
#: never did, and neither did 3000-byte pieces of it. SCTP's path MTU is around
#: 1200 bytes, so anything larger is fragmented before it goes out, and iOS
#: Safari does not put fragmented data channel messages back together. It drops
#: them with nothing at either end to say so.
#:
#: Staying under the MTU means every message crosses whole. Fifteen messages
#: instead of one costs nothing, and it is the difference between a styled page
#: and a black one.
THEME_CHUNK_BYTES = 800


def theme_chunks(css: str) -> list[str]:
    """The stylesheet as a series of messages the page concatenates.

    Ordered and reliable, so arrival order is send order and reassembly is just
    joining them up.
    """
    if not css:
        return [theme_message("", more=False)]
    parts = [css[i:i + THEME_CHUNK_BYTES] for i in range(0, len(css), THEME_CHUNK_BYTES)]
    return [theme_message(p, more=i < len(parts) - 1) for i, p in enumerate(parts)]


def theme_message(css: str, more: bool = False) -> str:
    """Push the stylesheet itself: the page has no HTTP route back to the Mac,
    so it receives the CSS rather than a hint to re-fetch it."""
    return json.dumps({"t": "theme", "css": css, "more": more})


def pong_message() -> str:
    return json.dumps({"t": "pong"})
