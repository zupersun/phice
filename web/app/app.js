/* Phice hosted client.
 *
 * Pairs by short code through the signaling letterbox, then talks to the Mac
 * over a direct WebRTC DataChannel. Contains no colours, sizes or labels: the
 * layout and the entire stylesheet are pushed from the Mac.
 */
(() => {
  "use strict";

  const CLIENT_VERSION = "9";

  const el = {
    body: document.body,
    haptic: document.getElementById("haptic"),
    pad: document.getElementById("pad"),
    code: document.getElementById("code"),
    theme: document.getElementById("theme"),
    why: document.getElementById("why"),
  };

  const state = {
    pc: null,
    channel: null,
    seq: 0,
    buttons: new Map(),          // id -> {el, role}
    touches: new Map(),          // touch identifier -> {id, lastY}
    pressed: new Map(),          // id -> bool
    counters: new Map(),         // id -> press count
    scrollDelta: 0,
    scrollPos: null,   // where the finger is along the strip, 0..1
    pending: {},       // channels seen so far, until both have opened
    pendingLogs: [],   // reports raised before there was anywhere to send them
    themeParts: [],    // the stylesheet arrives in pieces; see handleMessage
    orientation: null,
    rate: [0, 0, 0],
    gravity: [0, 0, 9.8],
    timer: null,
    motionTimes: [],
    hz: 0,
    perm: "",
  };

  // Two independent state machines, and they must stay independent:
  //   data-screen -- this page's own flow (pair / connecting / start / live),
  //                  styled by #shell, which the Mac never touches.
  //   data-state  -- the Mac engine's phase (off / on / hold / held), styled by
  //                  the pushed theme.
  // They used to share one attribute, so the Mac's first status message wiped
  // out the pairing flow.
  const setScreen = (s) => { el.body.dataset.screen = s; };

  // Appearance is chosen on the Mac and pushed down, so both surfaces match
  // without the phone needing a setting of its own. Remembered locally too:
  // the pairing screen is shown before any connection exists, and a returning
  // user should not watch it change colour a second after it appears.
  function setAppearance(mode) {
    const root = document.documentElement;
    if (mode === "system") root.removeAttribute("data-appearance");
    else root.setAttribute("data-appearance", mode);
    try { localStorage.setItem("phice.appearance", mode); } catch (_) { /* private mode */ }
  }
  try {
    const remembered = localStorage.getItem("phice.appearance");
    if (remembered) setAppearance(remembered);
  } catch (_) { /* falls back to the system appearance */ }

  // ---------- transport ----------
  //
  // One client, two ways in. Served from the Mac it opens a WebSocket straight
  // back to it; served from the hosted page it pairs by code and opens a WebRTC
  // data channel. The wire protocol is identical, so only the connecting
  // differs -- and keeping it to this one seam is what stopped the two clients
  // from drifting apart, which they had.

  async function localTransport() {
    // Only the Mac answers this. Vercel 404s, which means "pair by code".
    try {
      const r = await fetch("/transport", { cache: "no-store" });
      if (!r.ok) return null;
      return (await r.json()).transport === "ws";
    } catch (e) { return null; }
  }

  function openSocket() {
    setScreen("connecting");
    const ws = new WebSocket(`wss://${location.host}/ws`);
    const params = new URLSearchParams(location.search);
    ws.addEventListener("open", () => {
      const hello = { t: "hello", ver: 1, name: "iPhone", caps: hapticCaps() };
      // A one-shot pairing token from the setup QR, or the device token this
      // phone was given the first time it paired.
      const saved = localStorage.getItem("phice.token");
      if (params.get("pair")) hello.pair = params.get("pair");
      else if (saved) hello.token = saved;
      ws.send(JSON.stringify(hello));
      adopt({
        send: (text) => ws.send(text),
        sendControl: (text) => ws.send(text),   // one pipe, already reliable
        close: () => ws.close(),
        get open() { return ws.readyState === WebSocket.OPEN; },
      });
    });
    ws.addEventListener("message", (ev) => handleMessage(ev.data));
    ws.addEventListener("close", () => fail("The Mac closed the connection."));
    ws.addEventListener("error", () =>
      fail("Could not reach your Mac. Check that Phice is running and you are on the same network."));
  }

  // ---------- pairing ----------

  async function iceServers() {
    try {
      const r = await fetch("/api/ice");
      const body = await r.json();
      if (!body.relay) console.warn("no TURN relay:", body.reason);
      return body.iceServers;
    } catch (e) {
      // Never block pairing on this: STUN alone still works on a shared network.
      console.warn("ice config unavailable:", e);
      return [{ urls: "stun:stun.l.google.com:19302" }];
    }
  }

  async function pair(code) {
    setScreen("connecting");
    // Both peers take their ICE configuration from the same endpoint. Mismatched
    // lists gather candidates that cannot pair, and a relay is required whenever
    // the two devices are on different networks behind NAT.
    const pc = new RTCPeerConnection({ iceServers: await iceServers() });
    state.pc = pc;

    pc.addEventListener("datachannel", (ev) => wireChannel(ev.channel));
    state.pending = {};
    pc.addEventListener("connectionstatechange", () => {
      const s = pc.connectionState;
      // `disconnected` is transient: ICE dips into it routinely and recovers,
      // more often over a relay where there is more jitter. Treating it as fatal
      // tore down connections that were about to succeed. Only `failed` and
      // `closed` are terminal.
      if (s === "disconnected") {
        el.body.dataset.link = "unstable";
        return;
      }
      el.body.dataset.link = s === "connected" ? "ok" : "";
      if (s === "failed" || s === "closed") {
        fail("The connection dropped. Check that Phice is running on your Mac.");
      }
    });

    // The Mac shows a code the moment it mints one, before it has finished
    // gathering ICE candidates, so a code can be real and its offer not posted
    // yet. Give it a few seconds before declaring the code wrong.
    let offer = null;
    for (let attempt = 0; attempt < 10 && !offer; attempt++) {
      const res = await fetch(`/api/offer?code=${encodeURIComponent(code)}`);
      if (res.ok) { offer = await res.json(); break; }
      await new Promise((r) => setTimeout(r, 800));
    }
    if (!offer) {
      fail("That code was not found. Codes expire after five minutes — check your Mac for a fresh one.");
      return;
    }
    await pc.setRemoteDescription(offer);
    await pc.setLocalDescription(await pc.createAnswer());
    await gatherComplete(pc);

    const post = await fetch("/api/answer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, sdp: pc.localDescription.sdp, type: pc.localDescription.type }),
    });
    if (!post.ok) fail("Could not reach the pairing service.");
  }

  // Non-trickle: hand over one complete description rather than streaming candidates.
  function gatherComplete(pc) {
    if (pc.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        if (pc.iceGatheringState === "complete") {
          pc.removeEventListener("icegatheringstatechange", done);
          resolve();
        }
      };
      pc.addEventListener("icegatheringstatechange", done);
      setTimeout(resolve, 3000);   // publish what we have rather than hang
    });
  }

  function fail(why) {
    el.why.textContent = why;
    setScreen("failed");
  }

  // ---------- channel ----------

  function adopt(transport) {
    state.channel = transport;
    setTimeout(() => report("client v" + CLIENT_VERSION + " connected"), 0);   // flushes anything queued
    el.body.dataset.link = "ok";
    setScreen("start");
  }

  // Safari's console is unreachable from the Mac, so a page that fails silently
  // is a page nobody can debug. Anything that goes wrong goes back over the
  // control channel and into the Mac's log.
  function report(what) {
    state.pendingLogs.push(String(what));
    try {
      if (state.channel && state.channel.open) {
        for (const msg of state.pendingLogs.splice(0)) {
          state.channel.sendControl(JSON.stringify({ t: "log", msg }));
        }
      }
    } catch (_) { /* never let reporting a fault cause one */ }
  }
  window.addEventListener("error", (e) => report("error: " + (e.message || e)));
  window.addEventListener("unhandledrejection", (e) => report("rejected: " + e.reason));

  function handleMessage(data) {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (msg.t === "layout") {
      renderLayout(msg);
      report("layout: " + state.buttons.size + " buttons, pad "
             + el.pad.getBoundingClientRect().width.toFixed(0) + "x"
             + el.pad.getBoundingClientRect().height.toFixed(0));
    } else if (msg.t === "theme") {
      // Arrives in pieces: one big message never made it across at all on iOS,
      // with nothing at either end to say so. The channel is ordered, so
      // arrival order is send order and this is just concatenation.
      state.themeParts.push(msg.css);
      if (!msg.more) {
        el.theme.textContent = state.themeParts.join("");
        report("theme: " + el.theme.textContent.length + " bytes in "
               + state.themeParts.length + " parts");
        state.themeParts = [];
      }
    }
    else if (msg.t === "state") applyState(msg);
    else if (msg.t === "welcome" && msg.device_token) {
      // Given once, on the first pairing, so this phone can reconnect later
      // without another trip to the setup page.
      try { localStorage.setItem("phice.token", msg.device_token); } catch (_) { /* ignore */ }
    }
  }

  // Two channels arrive, and which is which matters. "phice" is unreliable and
  // unordered, right for 60 Hz sensor packets where a retransmitted stale one is
  // worse than none. "phice-ctl" is reliable, and everything that must arrive
  // goes over it -- the ~12 KB theme fragments across nine SCTP chunks, and on
  // the lossy channel losing any one discarded the lot, leaving unstyled buttons
  // on a black page with no error to show for it.
  function wireChannel(channel) {
    const control = channel.label === "phice-ctl";
    // Attach this first: the Mac sends the layout and theme the instant its own
    // end opens, and a message dispatched before anyone is listening is gone.
    if (control) {
      channel.addEventListener("message", (ev) => handleMessage(ev.data));
      channel.addEventListener("close", () => fail("The Mac closed the connection."));
    }
    const ready = () => {
      state.pending[control ? "ctl" : "data"] = channel;
      if (!state.pending.ctl) return;        // the session is the control channel
      const ctl = state.pending.ctl, data = state.pending.data || ctl;
      // Pairing already happened through the signaling code, so this hello exists
      // only to tell the Mac what this phone can do. Haptics have been guessed at
      // twice; the Mac logs this instead.
      ctl.send(JSON.stringify({ t: "hello", ver: 1, name: "iPhone", caps: hapticCaps() + ",v" + CLIENT_VERSION }));
      adopt({
        send: (text) => data.send(text),          // sensor packets: lossy is fine
        sendControl: (text) => ctl.send(text),    // must arrive
        close: () => { ctl.close(); if (data !== ctl) data.close(); },
        get open() { return ctl.readyState === "open"; },
      });
    };
    // A channel can already be open by the time this event reaches us, and then
    // "open" never fires at all -- which left the page sitting on
    // "Connecting..." forever, depending entirely on timing.
    if (channel.readyState === "open") ready();
    else channel.addEventListener("open", ready);
  }

  function applyState(msg) {
    // data-state drives everything visual, including the status LED, entirely from
    // the theme. Do NOT set --recenter-progress here: the browser interpolates it
    // itself from the data-state change via @property, and writing it per message
    // restarts the transition ~50 times a second and stutters.
    if (msg.phase && msg.phase !== el.body.dataset.state) {
      el.body.dataset.state = msg.phase;
      report("phase -> " + msg.phase);
    }
    if (msg.ui && msg.ui.recenter_ms) {
      el.body.style.setProperty("--recenter-ms", msg.ui.recenter_ms + "ms");
    }
    if (msg.ui) {
      state.haptics = !!msg.ui.haptics;
      if (msg.ui.appearance) setAppearance(msg.ui.appearance);
    }
  }

  // ---------- layout ----------

  function renderLayout(layout) {
    el.pad.innerHTML = "";
    state.buttons.clear();
    for (const b of layout.buttons || []) {
      const node = document.createElement("div");
      node.className = `btn role-${b.role}${b.class ? " " + b.class : ""}`;
      node.dataset.pressed = "0";
      node.style.left = b.x + "%";
      node.style.top = b.y + "%";
      node.style.width = b.w + "%";
      node.style.height = b.h + "%";
      if (b.icon) {
        const img = document.createElement("img");
        img.src = b.icon;            // resolved against the page; themes may inline instead
        node.appendChild(img);
      } else if (b.label) {
        node.textContent = b.label;
      }
      el.pad.appendChild(node);
      state.buttons.set(b.id, { el: node, role: b.role });
      if (!state.pressed.has(b.id)) { state.pressed.set(b.id, false); state.counters.set(b.id, 0); }
    }
  }

  // ---------- touch ----------

  function hitTest(x, y) {
    for (const [id, b] of state.buttons) {
      const r = b.el.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return id;
    }
    return null;
  }

  function setPressed(id, pressed) {
    const b = state.buttons.get(id);
    if (!b) return;
    if (pressed && !state.pressed.get(id)) {
      state.counters.set(id, (state.counters.get(id) || 0) + 1);
      haptic();
    }
    state.pressed.set(id, pressed);
    b.el.dataset.pressed = pressed ? "1" : "0";
    send(true);
  }

  function setScrollThumb(b, clientY) {
    const r = b.el.getBoundingClientRect();
    if (!r.height) return;
    // Clamped, so dragging past either end pins it there -- which is what makes
    // holding at the end mean "keep scrolling" rather than "stop".
    const pos = Math.min(1, Math.max(0, (clientY - r.top) / r.height));
    state.scrollPos = pos;
    b.el.style.setProperty("--scroll-pos", pos.toFixed(4));
  }

  el.pad.addEventListener("touchstart", (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const id = hitTest(t.clientX, t.clientY);
      if (!id) continue;
      state.touches.set(t.identifier, { id, lastY: t.clientY });
      const b = state.buttons.get(id);
      if (b && b.role === "scroll") setScrollThumb(b, t.clientY);
      setPressed(id, true);
    }
  }, { passive: false });

  el.pad.addEventListener("touchmove", (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const rec = state.touches.get(t.identifier);
      if (!rec) continue;
      const b = state.buttons.get(rec.id);
      if (b && b.role === "scroll") {
        state.scrollDelta += t.clientY - rec.lastY;
        setScrollThumb(b, t.clientY);
      }
      rec.lastY = t.clientY;
    }
  }, { passive: false });

  const endTouch = (ev) => {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const rec = state.touches.get(t.identifier);
      if (!rec) continue;
      state.touches.delete(t.identifier);
      const stillHeld = [...state.touches.values()].some((r) => r.id === rec.id);
      if (!stillHeld) {
        const b = state.buttons.get(rec.id);
        if (b && b.role === "scroll") {
          b.el.style.removeProperty("--scroll-pos");   // springs back, per the theme
          state.scrollPos = null;                      // and stops any edge scrolling
        }
        setPressed(rec.id, false);
      }
    }
  };
  el.pad.addEventListener("touchend", endTouch, { passive: false });
  el.pad.addEventListener("touchcancel", endTouch, { passive: false });

  // ---------- sensors ----------

  async function startSensors() {
    const D = window.DeviceOrientationEvent, M = window.DeviceMotionEvent;
    // Both prompts must be STARTED inside the user gesture. Awaiting the first
    // before asking for the second puts the second outside the gesture, and iOS
    // rejects it -- which aborted this function before a single listener was
    // attached, leaving a page that looked connected and sent nothing.
    const asks = [];
    if (D && typeof D.requestPermission === "function") asks.push(D.requestPermission());
    if (M && typeof M.requestPermission === "function") asks.push(M.requestPermission());
    const results = await Promise.allSettled(asks);
    // Report exactly what iOS answered. Guessing at the permission state from
    // the outside has cost hours; the Mac logs this and shows it in the panel.
    state.perm = (asks.length === 0 ? "no-prompt-api" : results.map((r, i) =>
      (i === 0 ? "orient=" : "motion=") +
      (r.status === "rejected" ? "threw:" + (r.reason && r.reason.name) : r.value)).join(","));
    if (state.channel && state.channel.open) {
      state.channel.sendControl(JSON.stringify({ t: "hello", ver: 1, name: "iPhone",
                                                 caps: hapticCaps() + ",v" + CLIENT_VERSION + "," + state.perm }));
    }
    // iOS resolves to "denied" WITHOUT throwing when Motion & Orientation Access
    // is off, or when this site was refused once before. Ignoring the result is
    // what made the failure silent.
    const denied = results.some((r) => r.status === "rejected" || r.value === "denied");

    window.addEventListener("deviceorientation", (e) => {
      state.orientation = [e.alpha, e.beta, e.gamma];
    });
    window.addEventListener("devicemotion", (e) => {
      noteMotionTick();
      const r = e.rotationRate || {};
      state.rate = [r.alpha || 0, r.beta || 0, r.gamma || 0];
      const g = e.accelerationIncludingGravity || {};
      state.gravity = [g.x || 0, g.y || 0, g.z || 9.8];
    });

    setScreen("live");
    const pad = el.pad.getBoundingClientRect();
    const first = el.pad.firstElementChild;
    const box = first ? first.getBoundingClientRect() : null;
    report("live: pad " + pad.width.toFixed(0) + "x" + pad.height.toFixed(0)
           + ", buttons " + state.buttons.size
           + (box ? ", first " + box.width.toFixed(0) + "x" + box.height.toFixed(0)
                  + " at " + box.left.toFixed(0) + "," + box.top.toFixed(0) : ""));
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(() => send(false), 1000 / 60);

    // Never leave a black screen. If the pad is empty or unstyled, the Mac's
    // layout or theme did not arrive, and sitting there silently is the single
    // most expensive symptom this project has had.
    if (!state.buttons.size || !el.theme.textContent) {
      report("live but nothing to show: buttons=" + state.buttons.size
             + " theme=" + el.theme.textContent.length);
      fail(!state.buttons.size
        ? "Your Mac did not send the button layout. Pull down to reload this page."
        : "Your Mac did not send the theme, so the buttons are invisible. "
          + "Pull down to reload this page.");
      return;
    }

    // Attaching a listener proves nothing: permission can be refused and the
    // events simply never arrive. The Mac then times the pointer out a second
    // after it is switched on, which reads as "it turns itself off".
    setTimeout(() => {
      if (state.orientation) return;
      clearInterval(state.timer);
      state.timer = null;
      if (state.channel && state.channel.open) {
        state.channel.sendControl(JSON.stringify({ t: "hello", ver: 1, name: "iPhone",
                                                   caps: "NO-MOTION," + state.perm }));
      }
      fail(denied
        ? "iPhone refused motion access for this site. Settings \u203a Apps \u203a Safari "
          + "\u203a Motion & Orientation Access must be ON. If it already is, that switch "
          + "also needs turning off and on again to clear a past refusal. Then reload."
        : "Connected, but the iPhone is sending no motion data. Settings \u203a Apps \u203a "
          + "Safari \u203a Motion & Orientation Access must be ON, then reload this page.");
    }, 2500);
  }

  // Safari exposes no way to request a sensor rate, so measure what actually
  // arrives rather than assume 60. Reported to the Mac, shown in /debug/cursor.
  function noteMotionTick() {
    const now = performance.now();
    state.motionTimes.push(now);
    while (state.motionTimes.length && now - state.motionTimes[0] > 1000) {
      state.motionTimes.shift();
    }
    state.hz = state.motionTimes.length;
  }

  // iOS has no Vibration API. Flipping a switch-style checkbox taps the Taptic
  // Engine, and WebKit only fires it for a click that arrives via the label --
  // clicking the input from script does nothing. Apple restricted this in
  // iOS 26.5, so on newer phones it is expected to do nothing at all; there is
  // no way to detect that from the page, and nothing else is available.
  function haptic() {
    if (!state.haptics) return;
    try {
      if (el.haptic && el.haptic.firstElementChild) el.haptic.click();
      else if (navigator.vibrate) navigator.vibrate(8);
    } catch (_) { /* never let feedback break input */ }
  }

  function hapticCaps() {
    const c = [];
    if (typeof navigator.vibrate === "function") c.push("vibrate");
    try {
      if ("switch" in document.createElement("input")) c.push("switch");
    } catch (_) { /* ignore */ }
    return c.join(",") || "none";
  }

  function send(force) {
    const ch = state.channel;
    if (!ch || !ch.open) return;
    if (!force && !state.orientation) return;
    const b = {}, c = {};
    for (const [id] of state.buttons) {
      b[id] = state.pressed.get(id) ? 1 : 0;
      c[id] = state.counters.get(id) || 0;
    }
    const sd = state.scrollDelta;
    state.scrollDelta = 0;
    state.seq += 1;
    ch.send(JSON.stringify({
      t: "s", seq: state.seq, ts: performance.now() / 1000,
      o: state.orientation,
      rr: state.rate.map((v) => Math.round(v * 100) / 100),
      g: state.gravity.map((v) => Math.round(v * 100) / 100),
      b, c, sd: Math.round(sd * 100) / 100,
      sp: state.scrollPos,
      hz: state.hz,
    }));
  }

  // ---------- wiring ----------

  el.code.addEventListener("input", () => {
    const clean = el.code.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
    if (clean !== el.code.value) el.code.value = clean;
  });

  document.getElementById("btn-pair").addEventListener("click", () => {
    const code = (el.code.value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (code.length !== 6) { el.code.focus(); return; }
    localStorage.setItem("phice.code", code);
    pair(code).catch((e) => fail(String(e)));
  });
  document.getElementById("btn-start").addEventListener("click", () => {
    startSensors().catch(() => fail("Motion access was denied. Allow it in Settings › Apps › Safari › Motion & Orientation Access."));
  });
  document.getElementById("btn-retry").addEventListener("click", () => setScreen("pair"));

  // A seam for the test harness. The client is otherwise sealed in this IIFE,
  // which is why nothing has ever executed it: every phone bug so far has been
  // in a file with no test able to reach inside it.
  window.__phice = { handleMessage, renderLayout, applyState, state, el };

  el.code.value = localStorage.getItem("phice.code") || "";
  setScreen("pair");
  localTransport().then((isLocal) => { if (isLocal) openSocket(); });
})();
