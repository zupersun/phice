#!/usr/bin/env python3
"""Replay a recorded session through the engine offline and print path statistics.

This is the tuning loop: record a minute of real use once, then compare
pointer.json variants without picking the phone up again.

    python tools/replay.py sessions/2026-09-11T14-02-11.jsonl --set gain_x_px_per_deg=40
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from phice.config import PointerConfig  # noqa: E402
from phice.cursor_backend import FakeCursor  # noqa: E402
from phice.engine import PointerEngine  # noqa: E402
from phice.protocol import Hello, ProtocolError, SensorPacket, parse_client_message  # noqa: E402


class ScriptedClock:
    """Replays the recorded arrival times so timing-dependent logic behaves."""

    def __init__(self):
        self.t = 0.0

    def __call__(self) -> float:
        return self.t


def coerce(value: str):
    low = value.lower()
    if low in ("true", "false"):
        return low == "true"
    try:
        return float(value) if "." in value else int(value)
    except ValueError:
        return value


def build_config(overrides: list[str], base: Path | None) -> PointerConfig:
    data = json.loads(base.read_text()) if base else {}
    for item in overrides:
        key, _, value = item.partition("=")
        target, parsed = data, coerce(value)
        parts = key.split(".")
        for p in parts[:-1]:
            target = target.setdefault(p, {})
        target[parts[-1]] = parsed
    return PointerConfig.from_dict(data)


def analyse(path: Path, config: PointerConfig) -> dict:
    clock = ScriptedClock()
    cursor = FakeCursor()
    engine = PointerEngine(config, cursor, clock)
    engine.connected()
    records = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    if not records:
        return {"packets": 0}
    t0 = records[0]["rx"]
    still_jitter, travel = 0.0, 0.0
    last = (cursor.x, cursor.y)
    packets, sessions = 0, 0
    for rec in records:
        clock.t = rec["rx"] - t0
        try:
            msg = parse_client_message(rec["raw"])
        except ProtocolError:
            continue
        if isinstance(msg, Hello):
            # A recording can span several connections; each one restarts seq at 1.
            sessions += 1
            engine.connected()
            continue
        if not isinstance(msg, SensorPacket):
            continue
        packets += 1
        engine.handle(msg)
        now = (cursor.x, cursor.y)
        step = math.dist(last, now)
        travel += step
        if msg.rate_dps < 2.0:
            still_jitter += step
        last = now
    events = cursor.kinds()
    return {"packets": packets, "sessions": sessions, "seconds": round(clock.t, 1),
            "travel_px": round(travel), "jitter_while_still_px": round(still_jitter, 1),
            "moves": events.count("move"), "drags": events.count("drag"),
            "clicks": events.count("down"), "scrolls": events.count("scroll"),
            "ended_held": sorted(cursor.held)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("session", type=Path)
    ap.add_argument("--config", type=Path, help="pointer.json to start from")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="override a tuning value, e.g. --set one_euro.beta=0.05")
    ap.add_argument("--compare", action="append", default=[], metavar="KEY=VALUE",
                    help="second variant to print beside the first")
    args = ap.parse_args()

    base = analyse(args.session, build_config(args.set, args.config))
    print(json.dumps({"variant": args.set or "baseline", **base}, indent=2))
    if args.compare:
        other = analyse(args.session, build_config(args.compare, args.config))
        print(json.dumps({"variant": args.compare, **other}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
