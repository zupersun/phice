import asyncio
import http.client
import json

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidHandshake

pytestmark = pytest.mark.asyncio


async def start(rig):
    port = await rig.server.start()
    return port


async def https_get(port, path, ctx):
    return await asyncio.to_thread(_https_get, port, path, ctx)


def _https_get(port, path, ctx):
    conn = http.client.HTTPSConnection("localhost", port, context=ctx, timeout=5)
    try:
        conn.request("GET", path)
        r = conn.getresponse()
        return r.status, r.getheader("Content-Type"), r.read()
    finally:
        conn.close()


async def open_ws(port, ctx, **kw):
    return await connect(f"wss://localhost:{port}/ws", ssl=ctx,
                         additional_headers={"Origin": f"https://localhost:{port}"}, **kw)


async def pair(rig, port, ctx):
    token = rig.state.pairing.mint_pairing_token()
    ws = await open_ws(port, ctx)
    await ws.send(json.dumps({"t": "hello", "ver": 1, "pair": token, "name": "iPhone"}))
    welcome = json.loads(await ws.recv())
    return ws, welcome["device_token"]


async def test_serves_page_and_assets_over_tls(rig, client_ssl):
    port = await start(rig)
    try:
        status, ctype, body = await https_get(port, "/", client_ssl)
        assert status == 200 and "text/html" in ctype and b"Phice" in body
        assert (await https_get(port, "/app.js", client_ssl))[0] == 200
        assert (await https_get(port, "/theme.css", client_ssl))[1].startswith("text/css")
        status, ctype, body = await https_get(port, "/layout.json", client_ssl)
        assert status == 200 and json.loads(body)["buttons"][0]["role"] == "power"
        assert (await https_get(port, "/assets/logo.svg", client_ssl))[1] == "image/svg+xml"
        assert (await https_get(port, "/assets/../devices.json", client_ssl))[0] == 404
        assert (await https_get(port, "/nope", client_ssl))[0] == 404
    finally:
        await rig.server.stop()


async def test_unpaired_connection_is_rejected(rig, client_ssl):
    port = await start(rig)
    try:
        ws = await open_ws(port, client_ssl)
        await ws.send(json.dumps({"t": "hello", "ver": 1, "name": "iPhone"}))
        err = json.loads(await ws.recv())
        assert err["t"] == "err" and err["code"] == "unpaired"
        with pytest.raises(ConnectionClosed):
            await ws.recv()
    finally:
        await rig.server.stop()


async def test_bad_origin_rejected(rig, client_ssl):
    port = await start(rig)
    try:
        with pytest.raises(InvalidHandshake):
            await connect(f"wss://localhost:{port}/ws", ssl=client_ssl,
                          additional_headers={"Origin": "https://evil.example"})
    finally:
        await rig.server.stop()


async def test_pairing_then_reconnect_with_device_token(rig, client_ssl):
    port = await start(rig)
    try:
        ws, device = await pair(rig, port, client_ssl)
        msgs = [json.loads(await ws.recv()) for _ in range(2)]
        assert {m["t"] for m in msgs} == {"layout", "state"}
        state = next(m for m in msgs if m["t"] == "state")
        assert state["phase"] == "off" and state["idle_hz"] == 0
        await ws.close()
        await asyncio.sleep(0.05)

        ws2 = await open_ws(port, client_ssl)
        await ws2.send(json.dumps({"t": "hello", "ver": 1, "token": device, "name": "iPhone"}))
        first = json.loads(await ws2.recv())
        assert first["t"] == "layout"  # no second welcome
        await ws2.close()
    finally:
        await rig.server.stop()


async def test_end_to_end_power_on_and_move(rig, client_ssl):
    port = await start(rig)
    try:
        ws, _ = await pair(rig, port, client_ssl)
        seq = 0

        async def send(alpha=0.0, **b):
            nonlocal seq
            seq += 1
            buttons = {"left": 0, "right": 0, "scroll": 0, "power": 0}
            buttons.update({k: int(v) for k, v in b.items()})
            await ws.send(json.dumps({"t": "s", "seq": seq, "ts": seq / 60, "o": [alpha, 0, 0],
                                      "rr": [10, 0, 0], "g": [0, 0, 9.8], "b": buttons,
                                      "c": {"left": 0, "right": 0, "scroll": 0, "power": 0}, "sd": 0}))

        await send()
        await send(power=True)
        await send(power=False)
        for _ in range(90):
            await send(alpha=350)
        await asyncio.sleep(0.2)
        assert rig.engine.phase.value == "on"
        assert rig.cursor.x > 300  # turned right by 10 degrees at 25 px/deg
        await ws.send(json.dumps({"t": "ping"}))
        for _ in range(20):  # drain the layout/state messages queued by the handshake
            if json.loads(await ws.recv())["t"] == "pong":
                break
        else:
            pytest.fail("no pong")
    finally:
        await rig.server.stop()


async def test_second_phone_replaces_the_first(rig, client_ssl):
    port = await start(rig)
    try:
        ws1, device = await pair(rig, port, client_ssl)
        ws2 = await open_ws(port, client_ssl)
        await ws2.send(json.dumps({"t": "hello", "ver": 1, "token": device, "name": "iPhone2"}))
        await asyncio.sleep(0.1)
        with pytest.raises(ConnectionClosed):
            while True:
                await ws1.recv()
        assert rig.state.client is not None
        await ws2.close()
    finally:
        await rig.server.stop()


async def test_disconnect_releases_held_button(rig, client_ssl):
    port = await start(rig)
    try:
        ws, _ = await pair(rig, port, client_ssl)
        seq = 0

        async def send(**b):
            nonlocal seq
            seq += 1
            buttons = {"left": 0, "right": 0, "scroll": 0, "power": 0}
            buttons.update({k: int(v) for k, v in b.items()})
            await ws.send(json.dumps({"t": "s", "seq": seq, "ts": seq / 60, "o": [0, 0, 0],
                                      "rr": [10, 0, 0], "g": [0, 0, 9.8], "b": buttons,
                                      "c": {"left": 0, "right": 0, "scroll": 0, "power": 0}, "sd": 0}))

        await send()
        await send(power=True)
        await send(power=False)
        await send(left=True)
        await asyncio.sleep(0.3)
        assert rig.cursor.held == {"left"}
        await ws.close()
        await asyncio.sleep(0.2)
        assert rig.cursor.held == set()
        assert rig.engine.phase.value == "disconnected"
    finally:
        await rig.server.stop()


async def test_malformed_packets_do_not_kill_the_session(rig, client_ssl):
    port = await start(rig)
    try:
        ws, _ = await pair(rig, port, client_ssl)
        for _ in range(5):
            await ws.send(json.dumps({"t": "s", "seq": 1, "ts": 1, "o": [999, 0, 0]}))
        await ws.send(json.dumps({"t": "ping"}))
        msgs = []
        for _ in range(4):
            msgs.append(json.loads(await ws.recv()))
            if msgs[-1]["t"] == "pong":
                break
        assert msgs[-1]["t"] == "pong"
    finally:
        await rig.server.stop()
