#!/usr/bin/env python3
"""Fake phone: drives a running Phice server over the real TLS socket.

The agent building this project cannot hold an iPhone, so this is how every
end-to-end behaviour gets verified.

    python tools/fake_phone.py --pattern sweep --check
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import ssl
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from websockets.asyncio.client import connect  # noqa: E402

from phice.certs import CertPaths  # noqa: E402
from phice.pairing import PairingManager  # noqa: E402
from phice.paths import Paths, default_config_dir  # noqa: E402

BUTTONS = ["left", "right", "scroll", "power"]


class FakePhone:
    def __init__(self, ws, hz: float = 60.0):
        self.ws = ws
        self.hz = hz
        self.seq = 0
        self.t = 0.0
        self.buttons = {b: False for b in BUTTONS}
        self.counters = {b: 0 for b in BUTTONS}

    async def send(self, alpha=0.0, beta=0.0, gamma=0.0, rr=(10.0, 0.0, 0.0), sd=0.0):
        self.seq += 1
        self.t += 1.0 / self.hz
        await self.ws.send(json.dumps({
            "t": "s", "seq": self.seq, "ts": self.t, "o": [alpha % 360, beta, gamma],
            "rr": list(rr), "g": [0.0, 0.0, 9.81],
            "b": {k: int(v) for k, v in self.buttons.items()}, "c": dict(self.counters),
            "sd": sd}))
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
    await p.power_on()
    await p.press("scroll")
    for _ in range(int(0.8 * p.hz)):
        await p.send(sd=-6.0)
    await p.release("scroll")
    await p.hold(0.2)


async def pattern_roll(p):
    """Roll the phone hard about its long axis: the cursor must not move."""
    await p.power_on(alpha=15, beta=10)
    for i in range(int(3 * p.hz)):
        await p.send(alpha=15, beta=10, gamma=60.0 * math.sin(i / p.hz * 2.2))


async def pattern_rest(p):
    await p.power_on()
    await p.hold(2.0, alpha=0.0, beta=0.0, rr=(0.2, 0.2, 0.2))


PATTERNS = {n[len("pattern_"):]: f for n, f in list(globals().items()) if n.startswith("pattern_")}


def debug_cursor(http_port: int) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/debug/cursor", timeout=5) as r:
        return json.loads(r.read())


async def replay(phone: FakePhone, path: Path) -> None:
    records = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    if not records:
        return
    t0 = records[0]["rx"]
    start = asyncio.get_running_loop().time()
    for rec in records:
        target = start + (rec["rx"] - t0)
        delay = target - asyncio.get_running_loop().time()
        if delay > 0:
            await asyncio.sleep(delay)
        await phone.ws.send(rec["raw"])


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
        return scrolled > 10 and clicks == 0 and moves == 0
    if pattern in ("still", "roll"):
        return moves == 0 and clicks == 0
    if pattern == "rest":
        return after.get("phase") in (None, "off")
    return True


async def run(args) -> int:
    paths = Paths(Path(args.config_dir) if args.config_dir else default_config_dir())
    pairing = PairingManager(paths.devices_json)
    token = pairing.mint_pairing_token()
    ctx = ssl.create_default_context(cafile=str(CertPaths.under(paths.certs).ca_crt))
    url = f"wss://{args.host}:{args.tls_port}/ws"
    before = debug_cursor(args.http_port) if args.check else None

    async with connect(url, ssl=ctx,
                       additional_headers={"Origin": f"https://{args.host}:{args.tls_port}"}) as ws:
        await ws.send(json.dumps({"t": "hello", "ver": 1, "pair": token, "name": args.name}))
        phone = FakePhone(ws, args.hz)

        async def drain():
            try:
                async for raw in ws:
                    msg = json.loads(raw)
                    if msg.get("t") == "err":
                        print("server error:", msg, file=sys.stderr)
                    elif args.verbose and msg.get("t") != "state":
                        print("<-", str(raw)[:140])
            except Exception:
                pass

        reader = asyncio.create_task(drain())
        if args.pattern == "replay":
            await replay(phone, Path(args.file))
        else:
            await PATTERNS[args.pattern](phone)
        reader.cancel()

    if not args.check:
        return 0
    after = debug_cursor(args.http_port)
    ok = check(args.pattern, before, after)
    print(json.dumps({"pattern": args.pattern, "before": before, "after": after}, indent=2))
    print("PASS" if ok else "FAIL", "-", args.pattern)
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pattern", default="sweep", choices=sorted(PATTERNS) + ["replay"])
    ap.add_argument("--file", help="session .jsonl for --pattern replay")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--tls-port", type=int, default=8443)
    ap.add_argument("--http-port", type=int, default=8080)
    ap.add_argument("--hz", type=float, default=60.0)
    ap.add_argument("--name", default="FakePhone")
    ap.add_argument("--config-dir")
    ap.add_argument("--check", action="store_true", help="assert the cursor did the right thing")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
