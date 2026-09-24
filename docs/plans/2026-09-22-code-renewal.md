# Pairing Code Renewal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The pairing code on the Mac is always either live, renewing, or visibly unable to reach the pairing service, and a phone that types it during a renewal still connects.

**Architecture:** The code stays stable for the whole run; what renews is the offer underneath it. The Mac takes the offer's lifetime from the letterbox's own reply instead of assuming it, ends its wait when a wall clock says the offer is gone (the loop's monotonic clock stops during sleep), and publishes the remaining life and any letterbox error through the status snapshot. The panel and menu bar render those states; the phone retries long enough to ride through a renewal and stops telling people to look for a code that never changes.

**Tech Stack:** Python 3.12 asyncio, the existing `signaling.py` letterbox client, the WKWebView panel (`templates.py` + `panel.css`), the hosted page (`web/app/app.js`), pytest.

---

## Pre-flight

### What happens today

- The code is deliberately stable for the whole process. Every five minutes the Mac republishes a fresh offer under the same code, because the letterbox drops offers after 300 s and the Mac waits exactly 300 s. The letterbox's reply already says `expires_in: 300`; the Mac ignores it.
- Between the old offer expiring and the new one being gathered and posted there is a gap of one to ten seconds. The phone retries for eight seconds and can miss it.
- The wait uses `loop.time()`, which is `time.monotonic()`, which on macOS is `mach_absolute_time()`. That clock does not advance while the Mac sleeps. After a sleep the letterbox has dropped the offer, but the Mac keeps showing the same code and keeps polling for up to the remaining five minutes before it republishes. The code on screen is dead and nothing says so.
- When the letterbox is unreachable, `signaling.run` writes `status.error`, which the panel never renders and the menu bar labels "Config error". The code sits on screen looking live.
- The phone's failure message says "check your Mac for a fresh one". The Mac's code does not change.

### Why renewal stays at expiry rather than thirty seconds before it

Renewing early sounds like it removes the gap. It does not. The letterbox keys answers by code only, so if the Mac publishes a new offer while the old one is still fetchable, a phone that fetched the old one answers it, the Mac applies that answer to the new peer connection, and ICE fails. That is strictly worse than a 404, which the phone can retry. Making it safe needs two peer connections overlapping and a late-answer check, which is more machinery than the gap deserves. So: renew when the letterbox's lifetime lapses, tell the panel that a renewal is in progress, and let the phone retry for twenty seconds.

### Not in scope

Rotating the code (Plan B), a longer letterbox lifetime (Plan C), any change to `web/api`.

---

## File structure

```
src/phice/
  signaling.py     MODIFIED: publish_offer returns the lifetime; wait_for_answer takes a
                   wall-clock expiry; Pairing records when and for how long; the loop
                   writes pairing_error, never error
  runtime.py       MODIFIED: Status.pairing_error; code_expires_in and code_life in the
                   debug snapshot
  menubar.py       MODIFIED: describe(status) -> (icon, label), pure and tested
  templates.py     MODIFIED: the code card publishes --code-life and data-pairing
  defaults/panel.css  MODIFIED: what those two mean

web/app/app.js     MODIFIED: 25 retries, honest wording, CLIENT_VERSION 11

tests/
  test_signaling.py   MODIFIED
  test_rtc.py         MODIFIED: loop tests
  test_runtime.py     MODIFIED: idle snapshot fields
  test_control.py     MODIFIED: panel markup and stylesheet
  test_menubar.py     NEW
  test_hosted_page.py MODIFIED

CLAUDE.md, docs/configuration.md   MODIFIED
```

---

### Task 1: The letterbox tells the Mac how long the offer lives

**Files:**
- Modify: `src/phice/signaling.py`
- Test: `tests/test_signaling.py`

- [ ] **Step 1: Write the failing tests**

In `tests/test_signaling.py`, change the stub's `do_POST` so the offer route answers the way `web/api/offer.js` does:

```python
        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n))
            kind = self.path.strip("/").split("/")[-1]
            store[f"{kind}:{data['code']}"] = data
            # offer.js reports the lifetime; answer.js does not.
            self._send(200, {"ok": True, "expires_in": 7} if kind == "offer" else {"ok": True})
```

Append:

```python
async def test_publishing_an_offer_reports_how_long_the_letterbox_keeps_it(stub):
    """The lifetime is the letterbox's to decide, and it says so in its reply.
    Assuming 300 on the Mac meant the two could disagree without anyone noticing."""
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    assert await c.publish_offer("ABC234", {"sdp": "x", "type": "offer"}) == 7.0


def test_a_letterbox_that_says_nothing_about_lifetime_gets_the_default():
    from phice.signaling import DEFAULT_OFFER_TTL_S, offer_ttl
    assert offer_ttl({"ok": True, "expires_in": 7}) == 7.0
    assert offer_ttl({"ok": True}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": "soon"}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl({"expires_in": 0}) == DEFAULT_OFFER_TTL_S
    assert offer_ttl(None) == DEFAULT_OFFER_TTL_S
```

- [ ] **Step 2: Run them and watch them fail**

Run: `uv run pytest tests/test_signaling.py -q`
Expected: two failures. `publish_offer` returns `None`; `offer_ttl` does not exist.

- [ ] **Step 3: Implement**

In `src/phice/signaling.py`, add after `HTTP_TIMEOUT = 10.0`:

```python
#: What web/api/offer.js keeps an offer for, used only if the letterbox's reply
#: does not say. The reply is authoritative: the two must never disagree.
DEFAULT_OFFER_TTL_S = 300.0


def offer_ttl(body: dict | None) -> float:
    """The lifetime a letterbox reply promises, or the default if it is silent."""
    value = (body or {}).get("expires_in")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        return DEFAULT_OFFER_TTL_S
    return float(value)
```

Replace `_post_sync` so it returns the reply:

```python
    def _post_sync(self, path: str, payload: dict) -> dict:
        body = json.dumps(payload).encode()
        req = urllib.request.Request(f"{self.base}{path}", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                raw = r.read()
        except (urllib.error.URLError, OSError) as e:
            raise SignalingError(f"POST {path} failed: {e}") from e
        try:
            reply = json.loads(raw) if raw else {}
        except ValueError:
            reply = {}
        return reply if isinstance(reply, dict) else {}
```

Replace `publish_offer`:

```python
    async def publish_offer(self, code: str, offer: dict) -> float:
        """Post the offer under the code. Returns how many seconds the letterbox
        will keep it, which is the letterbox's decision, not ours."""
        reply = await asyncio.to_thread(self._post_sync, "/api/offer", {"code": code, **offer})
        return offer_ttl(reply)
```

`publish_answer` is unchanged; it ignores the returned dict.

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_signaling.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/phice/signaling.py tests/test_signaling.py
git commit -m "feat: take the offer's lifetime from the letterbox's reply"
```

---

### Task 2: The wait ends when a wall clock says the offer is gone

**Files:**
- Modify: `src/phice/signaling.py`
- Test: `tests/test_signaling.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_signaling.py`:

```python
async def test_wait_for_answer_notices_a_wall_clock_that_moved_on(stub):
    """time.monotonic is mach_absolute_time on macOS, which stops while the Mac
    sleeps. The letterbox's clock does not. After a sleep the offer is gone,
    and the wait must end at once rather than run out its remaining minutes
    showing a dead code."""
    base, _ = stub
    c = SignalingClient(base, allow_insecure=True)
    ticks = iter([1000.0, 1000.2, 4600.0])          # the third reading is after a sleep
    with pytest.raises(SignalingError, match="expired"):
        await c.wait_for_answer("ZZZZZZ", timeout=30.0, interval=0.02,
                                expires_at=1000.5, clock=lambda: next(ticks))
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_signaling.py::test_wait_for_answer_notices_a_wall_clock_that_moved_on -q`
Expected: FAIL, `TypeError: ... unexpected keyword argument 'expires_at'`.

- [ ] **Step 3: Implement**

Add `import time` and `from collections.abc import Callable` to the imports in `src/phice/signaling.py`. Replace `wait_for_answer`:

```python
    async def wait_for_answer(self, code: str, timeout: float = DEFAULT_OFFER_TTL_S,
                              interval: float = 1.0, expires_at: float | None = None,
                              clock: Callable[[], float] = time.time) -> dict:
        """Poll until the phone answers. Polling, not streaming, because the
        whole exchange is two messages and serverless cannot hold a socket.

        Two clocks, on purpose. `timeout` runs on the loop's monotonic clock,
        which stops while the Mac sleeps; `expires_at` is compared against a
        wall clock, which does not. After a sleep the letterbox has dropped the
        offer, and only the wall clock knows.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            if expires_at is not None and clock() >= expires_at:
                raise SignalingError("the offer expired at the letterbox")
            got = await self.fetch_answer(code)
            if got:
                return got
            await asyncio.sleep(interval)
        raise SignalingError(f"waiting for the phone timed out after {timeout:.0f}s")
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_signaling.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/phice/signaling.py tests/test_signaling.py
git commit -m "fix: end the wait for an answer when the wall clock says the offer is gone"
```

---

### Task 3: The loop uses the lifetime and reports what it knows

**Files:**
- Modify: `src/phice/signaling.py` (the `Pairing` dataclass and `run`)
- Modify: `src/phice/runtime.py` (`Status`, `_debug_cursor`)
- Test: `tests/test_rtc.py`, `tests/test_runtime.py`

- [ ] **Step 1: Widen the existing fakes, then write the failing tests**

Four tests in `tests/test_rtc.py` already fake the signaling client. The loop will now
call `wait_for_answer(code, timeout=..., expires_at=...)`, and a fake that lists only
`timeout` and `interval` raises `TypeError` inside the task, which kills the loop
silently and turns one of them (`test_the_pairing_code_survives_a_reconnect`) into a
failure. In every `FakeSignaling` class in that file, change the signature to accept
anything:

```python
        async def wait_for_answer(self, code, **kw):
```

The bodies stay as they are. In the same classes, make every `publish_offer` return a
number, as the real client now does, by adding `return 300.0` as its last line. The
loop must not re-default a `None` here: `offer_ttl` already owns that rule, and two
sites owning it would drift. Then append to `tests/test_rtc.py`:

```python
async def test_the_loop_waits_as_long_as_the_letterbox_keeps_the_offer(tmp_path, monkeypatch):
    """The wait used to be a fixed 300 s, which happened to match the letterbox.
    It now takes the lifetime from the reply, waits one second past it so the
    letterbox has certainly dropped the old offer before a new one is gathered
    (a fetchable old offer is worse than a missing one), and hands the wait a
    wall-clock expiry."""
    import json as _json
    import time

    from phice.paths import Paths
    from phice.runtime import Runtime

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d["signaling_url"] = "https://example.invalid"
    paths.pointer_json.write_text(_json.dumps(d))

    seen: dict = {}

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def fetch_ice_servers(self):
            return None

        async def publish_offer(self, code, offer):
            seen["published_at"] = time.time()
            return 7.0

        async def wait_for_answer(self, code, **kw):
            seen["wait"] = kw
            await asyncio.sleep(3600)

    monkeypatch.setattr("phice.signaling.SignalingClient", FakeSignaling)
    rt = Runtime(paths, FakeCursor(), 0)
    rt.rtc_ice_servers = ()
    task = asyncio.ensure_future(signaling.run(rt))
    try:
        for _ in range(60):
            if "wait" in seen:
                break
            await asyncio.sleep(0.1)
        assert "wait" in seen, "the loop never got as far as waiting"
        assert seen["wait"]["timeout"] == 8.0
        assert abs(seen["wait"]["expires_at"] - (seen["published_at"] + 7.0)) < 0.5
        assert rt.pairing.ttl == 7.0
        assert abs(rt.pairing.published_at - seen["published_at"]) < 0.5
        snap = rt._debug_cursor()
        assert snap["offer_ready"] is True
        assert 5 <= snap["code_expires_in"] <= 7
        assert snap["code_life"] >= 0.7
        assert snap["pairing_error"] == ""
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        if rt.rtc:
            await rt.rtc.close()


async def test_an_unreachable_letterbox_is_reported_and_the_report_clears(tmp_path, monkeypatch):
    """The failure used to land in status.error, which the panel never showed
    and the menu bar called a config error. It has its own field, and it is
    cleared by the next successful publish, not by the next attempt. The retry
    is held behind an event so the transient state is observed, not raced."""
    import json as _json

    from phice.paths import Paths
    from phice.runtime import Runtime
    from phice.signaling import SignalingError

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    d = _json.loads(paths.pointer_json.read_text())
    d["signaling_url"] = "https://example.invalid"
    paths.pointer_json.write_text(_json.dumps(d))

    attempts: list[int] = []
    proceed = asyncio.Event()

    class FakeSignaling:
        def __init__(self, *a, **kw):
            pass

        async def fetch_ice_servers(self):
            return None

        async def publish_offer(self, code, offer):
            attempts.append(1)
            if len(attempts) == 1:
                raise SignalingError("POST /api/offer failed: no route to host")
            await proceed.wait()      # hold the retry until the test has seen the error
            return 300.0

        async def wait_for_answer(self, code, **kw):
            await asyncio.sleep(3600)

    monkeypatch.setattr("phice.signaling.SignalingClient", FakeSignaling)
    monkeypatch.setattr("phice.signaling.RETRY_S", 0.05)
    rt = Runtime(paths, FakeCursor(), 0)
    rt.rtc_ice_servers = ()
    task = asyncio.ensure_future(signaling.run(rt))
    try:
        for _ in range(60):
            if rt.status.read()["pairing_error"]:
                break
            await asyncio.sleep(0.1)
        assert "no route to host" in rt.status.read()["pairing_error"]
        assert rt.status.read()["error"] == "", "a letterbox failure is not a config error"
        proceed.set()
        for _ in range(60):
            if len(attempts) >= 2 and not rt.status.read()["pairing_error"]:
                break
            await asyncio.sleep(0.1)
        assert rt.status.read()["pairing_error"] == "", "cleared once a publish succeeds"
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        if rt.rtc:
            await rt.rtc.close()
```

In `tests/test_runtime.py`, extend `test_the_debug_snapshot_names_the_letterbox_and_the_phone_page` so its assertions read:

```python
    d = rt._debug_cursor()
    assert d["signaling_url"] == "https://phice.vercel.app"
    assert d["phone_url"] == "https://phice.vercel.app/app"
    assert d["offer_ready"] is False, "nothing published yet"
    assert d["code_expires_in"] == 0 and d["code_life"] == 0.0
    assert d["pairing_error"] == ""
    for gone in ("transport", "cert_mode", "phone_caps", "tls_url"):
        assert gone not in d
```

- [ ] **Step 2: Run them and watch them fail**

Run: `uv run pytest tests/test_rtc.py tests/test_runtime.py -q`
Expected: three failures. `KeyError: 'code_expires_in'`, `KeyError: 'pairing_error'`, and no `RETRY_S` to patch. The four older loop tests still pass.

- [ ] **Step 3: Implement the signaling side**

In `src/phice/signaling.py`, add after `DEFAULT_OFFER_TTL_S`:

```python
#: How long to wait before trying the letterbox again after it refused a publish.
RETRY_S = 10.0
```

Replace the `Pairing` dataclass:

```python
@dataclass
class Pairing:
    """The pairing code and the wait for an answer, shared between this loop and
    whoever asks for a fresh code from the panel.

    A small named thing rather than loose attributes on the runtime: they are
    only meaningful together, and `rotate` in particular has to be read in the
    same breath as `waiter` -- it is what tells a cancellation of that wait
    apart from the whole task being shut down.
    """

    #: Kept for the life of the process. Minting a new one after every
    #: disconnect sent the user back to the Mac each time, and the page's
    #: remembered code was always the dead one.
    code: str = ""
    waiter: asyncio.Task | None = None
    rotate: bool = False
    #: When the current offer was accepted by the letterbox (wall clock) and for
    #: how many seconds it promised to keep it. Together they are the code's
    #: remaining life, which the panel draws.
    published_at: float = 0.0
    ttl: float = 0.0
```

In `run`, replace the block from `code = rt.pairing.code or new_pairing_code()` down to the `finally:` clause with:

```python
        code = rt.pairing.code or new_pairing_code()
        rt.pairing.code = code
        rt.status.update(pair_code=code)

        offer = await rt.rtc.create_offer()
        try:
            ttl = await client.publish_offer(code, offer)
        except SignalingError as e:
            log.error("could not reach the pairing service: %s", e)
            # No offer is outstanding: keep the record saying so, rather than
            # relying on every reader to check `waiter` first.
            rt.pairing.published_at = 0.0
            rt.pairing.ttl = 0.0
            rt.status.update(pairing_error=str(e))
            await rt.rtc.close()
            await asyncio.sleep(RETRY_S)
            continue
        rt.pairing.published_at = time.time()
        rt.pairing.ttl = ttl
        rt.status.update(pairing_error="")
        log.info("pairing code %s -- enter it at %s/app", code, rt.config.signaling_url)
        # The wait ends when the wall clock reaches published_at + ttl. That
        # stamp was taken after the POST returned, so the letterbox's own clock
        # started earlier and has already dropped the offer by then, and closing
        # and gathering the next one adds more margin. A phone must never be
        # able to fetch the old offer once the Mac has moved on: that answer
        # fails on the new peer connection, whereas a missing offer is simply
        # retried. The monotonic ttl + 1 is only a backstop for a wall clock
        # that steps backwards.
        rt.pairing.waiter = asyncio.ensure_future(client.wait_for_answer(
            code, timeout=ttl + 1.0, expires_at=rt.pairing.published_at + ttl))
        try:
            answer = await rt.pairing.waiter
        except SignalingError as e:
            # Kept for the code and the promise of another offer. The reason
            # normally reads "expired at the letterbox"; "timed out" means the
            # wall clock stepped backwards and the backstop fired instead.
            log.info("offer under %s lapsed (%s); publishing another", code, e)
            await rt.rtc.close()
            continue
        except asyncio.CancelledError:
            # Two very different things arrive here: the panel asking for a
            # new code, and this whole task being shut down. Swallowing both
            # made the loop immortal -- the app could not quit and the test
            # suite hung at random.
            await rt.rtc.close()
            if not rt.pairing.rotate:
                raise
            rt.pairing.rotate = False
            continue
        finally:
            rt.pairing.waiter = None
            rt.pairing.rotate = False   # a stale request must not eat a shutdown
```

Note the top of the iteration no longer writes `error=""`: that field belongs to config reloads.

- [ ] **Step 4: Implement the runtime side**

In `src/phice/runtime.py`, add a field to `Status` and include it in `read()`:

```python
    pair_code: str = ""
    enabled: bool = True
    error: str = ""
    #: Set while the letterbox cannot be reached. Separate from `error`, which is
    #: about the config files: the panel and the menu bar say different things.
    pairing_error: str = ""

    def read(self) -> dict:
        with self.lock:
            return dict(connected=self.connected, device_name=self.device_name, phase=self.phase,
                        accessibility=self.accessibility, enabled=self.enabled,
                        pair_code=self.pair_code, error=self.error,
                        pairing_error=self.pairing_error)
```

In `_debug_cursor`, directly after the `offer_ready` line, add:

```python
        # The code's remaining life at the letterbox, from the wall clock so a
        # sleep shows as expired rather than paused. The panel draws code_life.
        p = self.pairing
        remaining = max(0.0, p.published_at + p.ttl - time.time()) if p.waiter else 0.0
        d["code_expires_in"] = round(remaining)
        d["code_life"] = round(min(1.0, remaining / p.ttl), 3) if p.ttl else 0.0
```

Add to `tests/test_runtime.py`, after `test_offer_ready_means_the_letterbox_holds_the_current_offer`:

```python
@pytest.mark.asyncio
async def test_code_life_never_shows_more_than_a_full_bar(tmp_path):
    """A wall clock that steps backwards makes the remaining life exceed the
    lifetime. The panel draws the fraction, so it is clamped at one."""
    import time

    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    rt = Runtime(paths, FakeCursor(), 0)
    rt.pairing.waiter = asyncio.get_running_loop().create_future()
    rt.pairing.ttl = 7.0
    rt.pairing.published_at = time.time() + 5.0
    assert rt._debug_cursor()["code_life"] == 1.0
    rt.pairing.waiter.cancel()
    rt.pairing.waiter = None
```

- [ ] **Step 5: Run the tests**

Run: `uv run pytest -q`
Expected: all pass, including the four older loop tests whose fakes you widened.

- [ ] **Step 6: Commit**

```bash
git add src/phice/signaling.py src/phice/runtime.py tests/test_rtc.py tests/test_runtime.py
git commit -m "feat: the pairing loop reports the code's remaining life and letterbox failures"
```

---

### Task 4: The panel shows which of the four states the code is in

**Files:**
- Modify: `src/phice/templates.py` (the code card and `refresh()`)
- Modify: `src/phice/defaults/panel.css`
- Test: `tests/test_control.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_control.py`:

```python
def test_the_panel_publishes_the_codes_life_as_a_number_and_its_state_as_an_attribute(control):
    """Same contract as the scroll strip and the knobs: the script sets a
    number and an attribute, and panel.css decides what they look like. It
    used to show the code alone, which looked identical whether the code was
    live, being renewed, or dead because the letterbox was unreachable."""
    html = get(control[1], "/panel")[2].decode()
    assert 'setProperty("--code-life"' in html
    assert "dataset.pairing" in html
    assert "code_life" in html and "offer_ready" in html and "pairing_error" in html
    assert 'id="code-hint"' in html
    assert "style=" not in html, "no inline style; numbers and attributes only"


def test_panel_css_styles_every_pairing_state():
    css = (DEFAULTS_DIR / "panel.css").read_text()
    assert "--code-life" in css
    for state in ("ready", "renewing", "error", "connected"):
        assert f'body[data-pairing="{state}"]' in css, state
```

Also update `test_panel_theme_control_touches_only_the_data_theme_attribute` so its final assertions read:

```python
    # The properties the script may publish are numbers: the knob's position
    # while a finger is on it, and the code's remaining life. What they look
    # like is the stylesheet's business.
    assert 'setProperty("--knob-drag"' in html
    assert 'setProperty("--code-life"' in html
```

- [ ] **Step 2: Run them and watch them fail**

Run: `uv run pytest tests/test_control.py -q`
Expected: three failures on the missing property, attribute and stylesheet rules.

- [ ] **Step 3: Change the markup**

In `src/phice/templates.py`, replace the pairing card:

```html
<div class="card" id="pair-card">
  <div class="code" id="code">······</div>
  <div class="code-life" aria-hidden="true"><i></i></div>
  <p class="code-hint" id="code-hint">Enter this on your phone</p>
</div>
```

In `refresh()`, directly after the line that sets `#url`, add:

```javascript
    // Which of four situations the code is in, and how much life it has left
    // (0..1). Only a number and an attribute cross this line; panel.css draws.
    const pairing = d.connected ? "connected"
                  : d.pairing_error ? "error"
                  : d.offer_ready ? "ready" : "renewing";
    document.body.dataset.pairing = pairing;
    document.body.style.setProperty("--code-life",
                                    (pairing === "ready" ? (d.code_life || 0) : 0).toFixed(3));
    document.getElementById("code-hint").textContent = {
      connected: "Connected. The code stays valid for next time.",
      error: "Can’t reach the pairing service. Phice keeps trying.",
      ready: "Enter this on your phone. It renews itself.",
      renewing: "Renewing…",
    }[pairing];
```

- [ ] **Step 4: Style the states**

Append to `src/phice/defaults/panel.css`, after the `.code-hint` rule:

```css
/* The code's remaining life at the pairing service, published by the script as
   --code-life (0..1), and its state as data-pairing on <body>: ready, renewing,
   error or connected. The bar drains as the offer runs out and refills when the
   Mac renews it under the same code. */
.code-life { height: 3px; margin: 2px 28px 8px; border-radius: 2px;
             background: var(--seg-track); overflow: hidden; }
.code-life i { display: block; height: 100%; background: var(--accent);
               width: calc(var(--code-life, 0) * 100%);
               transition: width 1s linear, background 200ms ease-out; }
body[data-pairing="ready"] .code-hint { color: var(--dim); }
body[data-pairing="renewing"] .code-life i { width: 100%; animation: renew 1.2s ease-in-out infinite; }
body[data-pairing="error"] .code { opacity: 0.35; }
body[data-pairing="error"] .code-life i { width: 100%; background: var(--bad); }
body[data-pairing="error"] .code-hint { color: var(--bad); }
body[data-pairing="connected"] .code-life { opacity: 0; }
@keyframes renew { 0%, 100% { opacity: 0.25; } 50% { opacity: 0.8; } }
@media (prefers-reduced-motion: reduce) {
  body[data-pairing="renewing"] .code-life i { animation: none; opacity: 0.4; }
}
```

- [ ] **Step 5: Run the tests**

Run: `uv run pytest tests/test_control.py -q`
Expected: all pass.

- [ ] **Step 6: See it**

Existing installs keep their own `panel.css`, so copy the new one in before looking:

```bash
cp src/phice/defaults/panel.css ~/Library/Application\ Support/Phice/panel.css
uv run phice install
```

Expected: the window shows the code with a thin bar under it that drains over five minutes and refills. Turn Wi-Fi off: within ten seconds the code dims, the bar turns red, and the hint says the pairing service cannot be reached. Turn it back on: the bar refills.

- [ ] **Step 7: Commit**

```bash
git add src/phice/templates.py src/phice/defaults/panel.css tests/test_control.py
git commit -m "feat: the panel shows whether the code is live, renewing, or cut off"
```

---

### Task 5: The menu bar names an unreachable letterbox

**Files:**
- Modify: `src/phice/menubar.py`
- Create: `tests/test_menubar.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_menubar.py`:

```python
"""The status line is decided by a pure function so it can be pinned here.

rumps is imported at module level by menubar.py; that is fine on macOS, which is
the only place the suite runs.
"""
from phice.menubar import describe


def _status(**kw) -> dict:
    s = dict(connected=False, device_name="", phase="disconnected", accessibility=True,
             enabled=True, pair_code="ABC234", error="", pairing_error="")
    s.update(kw)
    return s


def test_permission_comes_before_everything():
    assert describe(_status(accessibility=False, pairing_error="x")) == (
        "warn", "Accessibility permission needed")


def test_an_unreachable_letterbox_is_named_not_called_a_config_error():
    assert describe(_status(pairing_error="POST /api/offer failed")) == (
        "warn", "Can't reach the pairing service")


def test_the_ordinary_states():
    assert describe(_status()) == ("disconnected", "No phone connected")
    assert describe(_status(connected=True, device_name="iPhone", phase="on")) == (
        "on", "iPhone · pointer ON")
    assert describe(_status(connected=True, phase="off")) == ("off", "Phone · pointer off")
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_menubar.py -q`
Expected: FAIL, `ImportError: cannot import name 'describe'`.

- [ ] **Step 3: Implement**

In `src/phice/menubar.py`, add after `accessibility_trusted`:

```python
def describe(s: dict) -> tuple[str, str]:
    """Icon name and status line for a status snapshot, most urgent first.

    Pure, so the ordering is pinned by a test rather than by looking at the
    menu bar, which may be invisible behind the notch.
    """
    if not s["accessibility"]:
        return "warn", "Accessibility permission needed"
    if s.get("pairing_error"):
        return "warn", "Can't reach the pairing service"
    if not s["connected"]:
        return "disconnected", "No phone connected"
    name = s["device_name"] or "Phone"
    if s["phase"] in ("on", "hold", "held"):
        return "on", f"{name} · pointer ON"
    return "off", f"{name} · pointer off"
```

Replace the body of `refresh` from `s = self.runtime.status.read()` onward:

```python
        s = self.runtime.status.read()
        icon, label = describe(s)
        self._set_icon(icon)
        if s["error"]:
            label = f"Config error: {s['error'][:48]}"
        self.item_status.title = label
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_menubar.py -q`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add src/phice/menubar.py tests/test_menubar.py
git commit -m "fix: the menu bar says the pairing service is unreachable, not that config is wrong"
```

---

### Task 6: The phone rides through a renewal and stops sending people to look for a new code

**Files:**
- Modify: `web/app/app.js`
- Test: `tests/test_hosted_page.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_hosted_page.py` (add `import re` at the top):

```python
def test_the_phone_rides_through_a_renewal(js):
    """The Mac republishes under the same code every five minutes and needs a
    few seconds to gather the new offer. Eight seconds of retries could miss
    that window, and the message then sent people to the Mac for a fresh code
    that never changes."""
    m = re.search(r"attempt < (\d+) && !offer", js)
    assert m, "the retry loop moved"
    assert int(m.group(1)) * 800 >= 20_000, "retry for at least twenty seconds"
    assert "fresh one" not in js
    assert "renews the code by itself" in js
    assert 'CLIENT_VERSION = "11"' in js, "the client changed, so its version must"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `uv run pytest tests/test_hosted_page.py::test_the_phone_rides_through_a_renewal -q`
Expected: FAIL on the retry count.

- [ ] **Step 3: Implement**

In `web/app/app.js`:

```javascript
  const CLIENT_VERSION = "11";
```

Replace the retry loop and its failure in `pair()`:

```javascript
    // The Mac shows a code the moment it mints one, before it has finished
    // gathering ICE candidates, and it renews the offer under the same code
    // every few minutes with a gap of a few seconds while it gathers the next
    // one. Twenty seconds covers both.
    let offer = null;
    for (let attempt = 0; attempt < 25 && !offer; attempt++) {
      const res = await fetch(`/api/offer?code=${encodeURIComponent(code)}`);
      if (res.ok) { offer = await res.json(); break; }
      await new Promise((r) => setTimeout(r, 800));
    }
    if (!offer) {
      fail("Your Mac isn’t offering that code right now. Check the Phice window on the Mac: "
           + "it renews the code by itself, and it says so if it can’t reach the pairing service.");
      return;
    }
```

- [ ] **Step 4: Run the tests**

Run: `uv run pytest tests/test_hosted_page.py tests/test_client.py -q && node tests/client/run.mjs`
Expected: all pass; the client smoke ends with `all good`.

- [ ] **Step 5: Commit**

```bash
git add web/app/app.js tests/test_hosted_page.py
git commit -m "fix: the phone waits out a renewal instead of asking for a code that never changes"
```

---

### Task 7: Docs, deploy, and the full gate

**Files:**
- Modify: `CLAUDE.md`, `docs/configuration.md`

- [ ] **Step 1: Document the new readings**

In `CLAUDE.md`, add two rows to the diagnosing table after the `rtc.bad` row:

```markdown
| `code_expires_in` falling, `offer_ready: true` | Normal. When it reaches 0 the Mac renews the offer under the same code; the panel shows "Renewing…" for the few seconds that takes. |
| `pairing_error` set | The letterbox cannot be reached. The code on screen is not live, and the panel and menu bar both say so. It clears on the next successful publish. |
```

Add a constraint at the end of the numbered list:

```markdown
15. **The wait for an answer ends on a wall clock, not the loop's.** `time.monotonic`
    is `mach_absolute_time`, which stops while the Mac sleeps; the letterbox's clock does
    not. Without the wall-clock check a wake showed a dead code for up to five minutes.
    The stamp the wait counts from is taken *after* the publish returns, so by the time
    it fires the letterbox has already dropped the offer: an old offer that is still
    fetchable gets answered, and that answer fails on the new peer connection, whereas a
    missing offer is simply retried. The monotonic bound of lifetime plus one second is
    only a backstop for a wall clock that steps backwards.
```

In `docs/configuration.md`, change the `panel.css` row to:

```markdown
| `panel.css` | The Mac window: palette, the appearance switch, the pairing code's life bar, layout |
```

and add under the table:

```markdown
Existing installs keep the `panel.css` they have. After an update that adds to it,
`uv run phice reset-ui` restores the packaged one (backing yours up).
```

- [ ] **Step 2: Run the whole gate**

```bash
uv run pytest -q && uv run ruff check . && node tests/client/run.mjs
```

Expected: everything green.

- [ ] **Step 3: Deploy the page** (the user runs this; it publishes to Vercel)

The phone change is not live until the hosted page is:

```bash
./scripts/deploy-web.sh
```

Expected: `app.js matches`. Then on the phone, open the page fresh (it fetches `app.js` with a cache-busting query) and confirm the Mac logs `phone connected: ... v11`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/configuration.md
git commit -m "docs: the pairing code's life, and why the wait ends on a wall clock"
```

---

## Definition of done

1. `/debug/cursor` reports `code_expires_in` counting down from the letterbox's own lifetime, `code_life` between 1 and 0, and `pairing_error` when the letterbox is unreachable.
2. Closing the lid for ten minutes and reopening it: within two seconds the panel shows "Renewing…" and then a full bar, and a phone typing the code connects.
3. Turning Wi-Fi off dims the code and names the problem in both the panel and the menu bar; turning it on clears both.
4. A phone that types the code during a renewal sits on "Connecting…" for a few seconds and then connects.
5. `uv run pytest -q`, `uv run ruff check .` and `node tests/client/run.mjs` stay green.
