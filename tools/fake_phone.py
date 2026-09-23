#!/usr/bin/env python3
"""Fake phone: pairs with a running Phice the way an iPhone does and drives it.

It reads the pairing code and the letterbox address off the Mac's own debug
hook, fetches the offer from that letterbox, answers it over a WebRTC data
channel and then streams sensor packets. The agent building this project cannot
hold an iPhone, so this is how every end-to-end behaviour gets verified.

    uv run phice --config-dir /tmp/e2e --http-port 18080 run --backend fake --headless &
    uv run python tools/fake_phone.py --pattern sweep --check --http-port 18080

Pairing goes through whatever `signaling_url` the Mac is configured with, so
this needs the letterbox to be reachable -- the hosted one by default.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from aiortc import (  # noqa: E402
    RTCConfiguration,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)

from phice.paths import client_version  # noqa: E402
from phice.rtc import gather_complete  # noqa: E402
from phice.signaling import SignalingClient  # noqa: E402

BUTTONS = ["left", "right", "scroll", "power"]


class FakePhone:
    def __init__(self, send, hz: float = 60.0):
        self._send = send
        self.hz = hz
        self.seq = 0
        self.t = 0.0
        self.buttons = {b: False for b in BUTTONS}
        self.counters = {b: 0 for b in BUTTONS}

    async def send(self, alpha=0.0, beta=0.0, gamma=0.0, rr=(10.0, 0.0, 0.0), sd=0.0, sp=None):
        self.seq += 1
        self.t += 1.0 / self.hz
        self._send(json.dumps({
            "t": "s", "seq": self.seq, "ts": self.t, "o": [alpha % 360, beta, gamma],
            "rr": list(rr), "g": [0.0, 0.0, 9.81],
            "b": {k: int(v) for k, v in self.buttons.items()}, "c": dict(self.counters),
            "sd": sd, "sp": sp}))
        await asyncio.sleep(1.0 / self.hz)

    async def press(self, name, alpha=0.0, beta=0.0):
        self.counters[name] += 1
        self.buttons[name] = True
        await self.send(alpha, beta)

    async def release(self, name, alpha=0.0, beta=0.0):
        self.buttons[name] = False
        await self.send(alpha, beta)

    async def hold(self, seconds, alpha=0.0, beta=0.0, gamma=0.0, rr=(10.0, 0.0, 0.0)):
        for _ in range(max(1, int(seconds * self.hz))):
            await self.send(alpha, beta, gamma, rr)

    async def power_on(self, alpha=0.0, beta=0.0):
        """Settle at the aim first, so powering on never itself moves the cursor."""
        await self.hold(0.3, alpha=alpha, beta=beta)
        await self.press("power", alpha=alpha, beta=beta)
        await self.release("power", alpha=alpha, beta=beta)
        await self.hold(0.3, alpha=alpha, beta=beta)


async def pattern_still(p):
    await p.hold(2.0)


async def pattern_sweep(p):
    await p.power_on()
    for i in range(int(4 * p.hz)):
        await p.send(alpha=-20.0 * math.sin(i / p.hz * math.pi), beta=8.0 * math.sin(i / p.hz * 1.7))


async def pattern_square(p):
    await p.power_on()
    for a, b in ((0, 0), (-10, 0), (-10, 10), (0, 10), (0, 0)):
        await p.hold(0.7, alpha=a, beta=b)


async def pattern_click(p):
    await p.power_on()
    await p.press("left")
    await p.hold(0.08)
    await p.release("left")
    await p.hold(0.3)


async def pattern_doubleclick(p):
    await p.power_on()
    for _ in range(2):
        await p.press("left")
        await p.hold(0.05)
        await p.release("left")
        await p.hold(0.08)
    await p.hold(0.4)


async def pattern_rightclick(p):
    await p.power_on()
    await p.press("right")
    await p.hold(0.08)
    await p.release("right")
    await p.hold(0.3)


async def pattern_drag(p):
    await p.power_on()
    await p.press("left")
    await p.hold(0.25)
    for i in range(int(1.2 * p.hz)):
        await p.send(alpha=-8.0 * i / (1.2 * p.hz))
    await p.release("left", alpha=-8.0)
    await p.hold(0.2)


async def pattern_chord(p):
    await p.power_on()
    await p.press("left")
    await p.press("right")
    await p.hold(1.4)
    await p.release("left")
    await p.release("right")
    await p.hold(0.3)


async def pattern_scroll(p):
    """The strip is a rate control: speed comes from where the finger sits, so
    holding it near the end keeps scrolling. `sd` alone does nothing by default."""
    await p.power_on()
    await p.press("scroll")
    for _ in range(int(0.8 * p.hz)):
        await p.send(sd=-6.0, sp=0.95)
    await p.release("scroll")
    await p.hold(0.2)


async def pattern_roll(p):
    """Roll the phone hard about its long axis: the cursor must not move."""
    await p.power_on(alpha=15, beta=10)
    for i in range(int(3 * p.hz)):
        await p.send(alpha=15, beta=10, gamma=60.0 * math.sin(i / p.hz * 2.2))


async def pattern_rest(p):
    """Lie flat and still for longer than `rest_seconds`: the pointer switches itself off."""
    await p.power_on()
    await p.hold(3.5, alpha=0.0, beta=0.0, rr=(0.2, 0.2, 0.2))


PATTERNS = {n[len("pattern_"):]: f for n, f in list(globals().items()) if n.startswith("pattern_")}


def debug_cursor(http_port: int) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/debug/cursor", timeout=5) as r:
        return json.loads(r.read())


async def replay(send, path: Path) -> None:
    records = [json.loads(ln) for ln in path.read_text().splitlines() if ln.strip()]
    if not records:
        return
    t0 = records[0]["rx"]
    start = asyncio.get_running_loop().time()
    for rec in records:
        target = start + (rec["rx"] - t0)
        delay = target - asyncio.get_running_loop().time()
        if delay > 0:
            await asyncio.sleep(delay)
        send(rec["raw"])


def check(pattern: str, before: dict, after: dict) -> bool:
    """Count *events*, not net displacement: a closed path ends where it began."""
    moves = after.get("moves", 0) - before.get("moves", 0)
    clicks = after.get("clicks", 0) - before.get("clicks", 0)
    scrolled = abs(after.get("scroll", 0) - before.get("scroll", 0))
    held = after.get("held") or []
    centered = (after.get("x"), after.get("y"))
    if pattern in ("sweep", "square"):
        return moves > 30 and clicks == 0 and not held
    if pattern in ("click", "rightclick"):
        return clicks == 1 and not held
    if pattern == "doubleclick":
        return clicks == 2 and not held
    if pattern == "drag":
        return clicks == 1 and moves > 10 and not held
    if pattern == "chord":
        return clicks == 0 and not held and centered == (720.0, 450.0)
    if pattern == "scroll":
        # Powering on snaps the cursor once; the strip must freeze it after that.
        return scrolled > 10 and clicks == 0 and moves <= 1
    if pattern == "still":
        return moves == 0 and clicks == 0
    if pattern == "roll":
        # Powering on snaps the cursor to the centre; rolling must leave it there.
        return clicks == 0 and centered == (720.0, 450.0) and moves <= 5
    if pattern == "rest":
        return after.get("phase") in (None, "off")
    return True


async def pair(http_port: int, name: str, verbose: bool) -> tuple[RTCPeerConnection, object, object]:
    """Do what the page does: fetch the offer under the Mac's code, answer it.

    Returns the peer connection and its two channels once both are open."""
    # Wait for the Mac to say its current offer is in the letterbox. After the
    # previous session ends the old offer lingers there while the fresh one is
    # gathered, and answering that one fails ICE every time.
    status = None
    for _ in range(300):
        status = debug_cursor(http_port)
        if status.get("pair_code") and status.get("offer_ready"):
            break
        await asyncio.sleep(0.2)
    else:
        raise SystemExit(f"the Mac is not offering a pairing code: {status}")
    code, letterbox = status["pair_code"], status["signaling_url"]
    client = SignalingClient(letterbox, allow_insecure=True)
    print(f"pairing with code {code} via {letterbox}")

    ice = await client.fetch_ice_servers()
    servers = [RTCIceServer(urls=s["urls"], username=s.get("username"),
                            credential=s.get("credential")) for s in (ice or [])]
    pc = RTCPeerConnection(configuration=RTCConfiguration(iceServers=servers))
    channels: dict[str, object] = {}
    opened = asyncio.get_running_loop().create_future()

    @pc.on("datachannel")
    def on_channel(channel):
        channels[channel.label] = channel

        @channel.on("message")
        def on_message(raw):
            msg = json.loads(raw)
            if msg.get("t") == "err":
                print("server error:", msg, file=sys.stderr)
            elif verbose and msg.get("t") != "state":
                print("<-", str(raw)[:140])

        if {"phice", "phice-ctl"} <= channels.keys() and not opened.done():
            opened.set_result(True)

    # The Mac shows the code before its offer is fully gathered, so retry.
    offer = None
    for _ in range(40):
        offer = await client.fetch_offer(code)
        if offer:
            break
        await asyncio.sleep(0.5)
    if not offer:
        raise SystemExit(f"no offer under {code} at {letterbox}")
    await pc.setRemoteDescription(RTCSessionDescription(sdp=offer["sdp"], type=offer["type"]))
    await pc.setLocalDescription(await pc.createAnswer())
    await gather_complete(pc)
    await client.publish_answer(code, {"sdp": pc.localDescription.sdp,
                                       "type": pc.localDescription.type})
    await asyncio.wait_for(opened, timeout=60)
    ctl, data = channels["phice-ctl"], channels["phice"]
    ctl.send(json.dumps({"t": "hello", "ver": 1, "name": name,
                         "caps": "fake,v" + client_version()}))
    return pc, ctl, data


async def run(args) -> int:
    before = debug_cursor(args.http_port) if args.check else None
    pc, _ctl, data = await pair(args.http_port, args.name, args.verbose)
    try:
        phone = FakePhone(data.send, args.hz)
        if args.pattern == "replay":
            await replay(data.send, Path(args.file))
        else:
            await PATTERNS[args.pattern](phone)
        await asyncio.sleep(0.3)             # let the last packets land
        after = debug_cursor(args.http_port) if args.check else None
    finally:
        await pc.close()

    if not args.check:
        return 0
    ok = check(args.pattern, before, after)
    print(json.dumps({"pattern": args.pattern, "before": before, "after": after}, indent=2))
    print("PASS" if ok else "FAIL", "-", args.pattern)
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pattern", default="sweep", choices=sorted(PATTERNS) + ["replay"])
    ap.add_argument("--file", help="session .jsonl for --pattern replay")
    ap.add_argument("--http-port", type=int, default=8080)
    ap.add_argument("--hz", type=float, default=60.0)
    ap.add_argument("--name", default="FakePhone")
    ap.add_argument("--check", action="store_true", help="assert the cursor did the right thing")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
