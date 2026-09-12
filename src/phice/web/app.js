/* Phice phone client.
 *
 * Responsibilities: request sensor access, render the layout the Mac sends,
 * track multi-touch button state, and stream everything to the Mac. All
 * pointer behaviour lives on the Mac; this file decides nothing.
 * No colours, sizes or labels here -- those come from theme.css and layout.json.
 */
(() => {
  "use strict";

  const PROTOCOL_VERSION = 1;
  const TOKEN_KEY = "phice.device_token";
  const RECONNECT_MIN_MS = 500;
  const RECONNECT_MAX_MS = 5000;
  const IDLE_PING_MS = 5000;

  const el = {
    body: document.body,
    pad: document.getElementById("pad"),
    status: document.getElementById("status"),
    start: document.getElementById("btn-start"),
    retry: document.getElementById("btn-retry"),
    hapticTest: document.getElementById("btn-haptic-test"),
    haptic: document.getElementById("haptic"),
    hapticLabel: document.getElementById("haptic-label"),
  };

  const state = {
    ws: null,
    seq: 0,
    backoff: RECONNECT_MIN_MS,
    phase: "off",
    idleHz: 0,
    haptics: true,
    keepAwake: "always",
    sensorsOn: false,
    wakeLock: null,
    lastSendAt: 0,
    lastPingAt: 0,
    buttons: new Map(),   // id -> {role, pressed, count, el, rect}
    touches: new Map(),   // touch identifier -> {id, lastY}
    scrollDelta: 0,
    motionTimes: [],
    hz: 0,
    orientation: null,    // [alpha, beta, gamma]
    rotationRate: [0, 0, 0],
    gravity: [0, 0, 0],
  };

  // ---------- utilities ----------

  function setPageState(s) {
    el.body.dataset.state = s;
  }

  function hapticCaps() {
    const c = [];
    if (typeof navigator.vibrate === "function") c.push("vibrate");
    try {
      if ("switch" in document.createElement("input")) c.push("switch");
    } catch (_) { /* ignore */ }
    if (el.hapticLabel) c.push("label");
    return c.join(",") || "none";
  }

  function tick() {
    if (!state.haptics) return;
    // Safari has historically had no vibration API, so the only route is toggling
    // a native `switch` control -- and only by clicking the LABEL, and only while
    // the control is genuinely rendered. Try the standard API first in case a
    // newer iOS has gained it.
    try {
      if (typeof navigator.vibrate === "function") { navigator.vibrate(10); }
    } catch (_) { /* ignore */ }
    try {
      const target = el.hapticLabel || el.haptic;
      if (target) target.click();
    } catch (_) { /* ignore */ }
  }

  function num(v) { return typeof v === "number" && isFinite(v) ? v : 0; }

  // ---------- rendering ----------

  function renderLayout(layout) {
    state.buttons.clear();
    state.touches.clear();
    el.pad.textContent = "";
    for (const b of layout.buttons || []) {
      const node = document.createElement("div");
      node.className = `btn role-${b.role} id-${b.id}${b.class ? " " + b.class : ""}`;
      node.dataset.id = b.id;
      node.dataset.role = b.role;
      node.dataset.pressed = "0";
      node.style.left = b.x + "%";
      node.style.top = b.y + "%";
      node.style.width = b.w + "%";
      node.style.height = b.h + "%";
      if (b.icon) {
        const img = document.createElement("img");
        img.src = "/assets/" + b.icon;
        img.alt = "";
        node.appendChild(img);
      } else if (b.label) {
        const span = document.createElement("span");
        span.className = "label";
        span.textContent = b.label;
        node.appendChild(span);
      }
      el.pad.appendChild(node);
      state.buttons.set(b.id, { role: b.role, pressed: false, count: 0, el: node });
    }
  }

  function hitTest(x, y) {
    for (const [id, b] of state.buttons) {
      const r = b.el.getBoundingClientRect();
      if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) return id;
    }
    return null;
  }

  function setPressed(id, pressed) {
    const b = state.buttons.get(id);
    if (!b || b.pressed === pressed) return;
    b.pressed = pressed;
    if (pressed) b.count += 1;
    b.el.dataset.pressed = pressed ? "1" : "0";
    if (pressed) tick();
    sendPacket(true);
  }

  // ---------- touch ----------

  // Where the finger is on the scroll strip, 0 (top) to 1 (bottom). theme.css
  // turns this into the thumb's position, so the rendering stays in the theme.
  function setScrollThumb(b, clientY) {
    const r = b.el.getBoundingClientRect();
    if (!r.height) return;
    const pos = Math.min(1, Math.max(0, (clientY - r.top) / r.height));
    b.el.style.setProperty("--scroll-pos", pos.toFixed(4));
  }


  function onTouchStart(ev) {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const id = hitTest(t.clientX, t.clientY);
      if (!id) continue;
      state.touches.set(t.identifier, { id, lastY: t.clientY });
      const b = state.buttons.get(id);
      if (b && b.role === "scroll") setScrollThumb(b, t.clientY);
      setPressed(id, true);
    }
  }

  function onTouchMove(ev) {
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
  }

  function endTouch(ev) {
    ev.preventDefault();
    for (const t of ev.changedTouches) {
      const rec = state.touches.get(t.identifier);
      if (!rec) continue;
      state.touches.delete(t.identifier);
      const stillHeld = [...state.touches.values()].some((r) => r.id === rec.id);
      if (!stillHeld) {
        const b = state.buttons.get(rec.id);
        if (b && b.role === "scroll") b.el.style.removeProperty("--scroll-pos");
        setPressed(rec.id, false);
      }
    }
  }

  el.pad.addEventListener("touchstart", onTouchStart, { passive: false });
  el.pad.addEventListener("touchmove", onTouchMove, { passive: false });
  el.pad.addEventListener("touchend", endTouch, { passive: false });
  el.pad.addEventListener("touchcancel", endTouch, { passive: false });
  document.addEventListener("gesturestart", (e) => e.preventDefault());
  document.addEventListener("contextmenu", (e) => e.preventDefault());

  // ---------- sensors ----------

  function onOrientation(ev) {
    if (ev.alpha === null && ev.beta === null) return;
    state.orientation = [num(ev.alpha), num(ev.beta), num(ev.gamma)];
  }

  // Safari exposes no way to request a sensor rate, so measure what we actually
  // get rather than assume. Reported to the Mac and shown in /debug/cursor.
  function noteMotionTick() {
    const now = performance.now();
    state.motionTimes.push(now);
    while (state.motionTimes.length && now - state.motionTimes[0] > 1000) {
      state.motionTimes.shift();
    }
    state.hz = state.motionTimes.length;
  }

  function onMotion(ev) {
    noteMotionTick();
    const rr = ev.rotationRate || {};
    state.rotationRate = [num(rr.alpha), num(rr.beta), num(rr.gamma)];
    const g = ev.accelerationIncludingGravity || {};
    state.gravity = [num(g.x), num(g.y), num(g.z)];
    sendPacket(false);
  }

  function startSensors() {
    if (state.sensorsOn) return;
    window.addEventListener("deviceorientation", onOrientation);
    window.addEventListener("devicemotion", onMotion);
    state.sensorsOn = true;
  }

  function stopSensors() {
    if (!state.sensorsOn) return;
    window.removeEventListener("deviceorientation", onOrientation);
    window.removeEventListener("devicemotion", onMotion);
    state.sensorsOn = false;
  }

  async function requestSensorPermission() {
    const asks = [];
    for (const C of [window.DeviceMotionEvent, window.DeviceOrientationEvent]) {
      if (C && typeof C.requestPermission === "function") asks.push(C.requestPermission());
    }
    if (!asks.length) return true;   // non-iOS browsers grant implicitly
    try {
      const results = await Promise.all(asks);
      return results.every((r) => r === "granted");
    } catch (_) {
      return false;
    }
  }

  async function acquireWakeLock() {
    if (!("wakeLock" in navigator)) return;
    const want = state.keepAwake === "always" || state.phase !== "off";
    if (!want) return;
    try {
      state.wakeLock = await navigator.wakeLock.request("screen");
      state.wakeLock.addEventListener("release", () => { state.wakeLock = null; });
    } catch (_) { /* denied or not visible */ }
  }

  // ---------- transport ----------

  function sendPacket(force) {
    const ws = state.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const now = performance.now();
    const active = state.phase !== "off";
    const minGap = active ? 0 : (state.idleHz > 0 ? 1000 / state.idleHz : Infinity);
    if (!force && now - state.lastSendAt < minGap) return;
    state.lastSendAt = now;
    state.seq += 1;
    const b = {}, c = {};
    for (const [id, btn] of state.buttons) { b[id] = btn.pressed ? 1 : 0; c[id] = btn.count; }
    const sd = state.scrollDelta;
    state.scrollDelta = 0;
    ws.send(JSON.stringify({
      t: "s", seq: state.seq, ts: now / 1000,
      o: state.orientation, rr: state.rotationRate, g: state.gravity,
      b, c, sd: Math.round(sd * 100) / 100,
      hz: state.hz,
    }));
  }

  function applyState(msg) {
    state.phase = msg.phase;
    state.idleHz = msg.idle_hz | 0;
    if (msg.ui) {
      state.haptics = !!msg.ui.haptics;
      state.keepAwake = msg.ui.keep_awake;
      if (msg.ui.recenter_ms) {
        el.body.style.setProperty("--recenter-ms", msg.ui.recenter_ms + "ms");
      }
    }
    setPageState(msg.phase);
    // Deliberately NOT setting --recenter-progress here. The browser animates it
    // from the data-state change, which is smooth at 60fps; setting it per message
    // restarted the transition ~50 times a second and stuttered.
    if (msg.phase === "held" && state.lastPhase !== "held") { tick(); setTimeout(tick, 90); }
    state.lastPhase = msg.phase;
    el.status.textContent = !msg.accessibility
      ? "Mac needs Accessibility permission"
      : (msg.phase === "off" ? "Ready — tap POWER" : "Pointer active");
    if (state.phase === "off" && state.idleHz === 0) stopSensors(); else startSensors();
    acquireWakeLock();
  }

  function connect() {
    const params = new URLSearchParams(location.search);
    const pair = params.get("pair");
    const token = localStorage.getItem(TOKEN_KEY);
    const ws = new WebSocket(`wss://${location.host}/ws`);
    state.ws = ws;

    ws.onopen = () => {
      state.backoff = RECONNECT_MIN_MS;
      const hello = { t: "hello", ver: PROTOCOL_VERSION, name: "iPhone" };
      if (token) hello.token = token; else if (pair) hello.pair = pair;
      ws.send(JSON.stringify(hello));
    };

    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (_) { return; }
      if (msg.t === "welcome") {
        localStorage.setItem(TOKEN_KEY, msg.device_token);
        history.replaceState(null, "", location.pathname);
      } else if (msg.t === "layout") {
        renderLayout(msg);
      } else if (msg.t === "state") {
        applyState(msg);
      } else if (msg.t === "theme_changed") {
        const link = document.getElementById("theme");
        link.href = "/theme.css?v=" + Date.now();
      } else if (msg.t === "err") {
        el.status.textContent = msg.msg;
        if (msg.code === "unpaired") localStorage.removeItem(TOKEN_KEY);
      }
    };

    ws.onclose = () => {
      state.ws = null;
      stopSensors();
      setPageState("disconnected");
      setTimeout(connect, state.backoff);
      state.backoff = Math.min(state.backoff * 2, RECONNECT_MAX_MS);
    };

    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }

  // ---------- idle ping ----------

  setInterval(() => {
    const ws = state.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    if (state.phase === "off" && state.idleHz === 0) {
      ws.send(JSON.stringify({ t: "ping" }));
    }
  }, IDLE_PING_MS);

  // ---------- lifecycle ----------

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      stopSensors();
      const ws = state.ws;
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ t: "bye" }));
    } else {
      acquireWakeLock();
      if (!state.ws) connect();
    }
  });

  async function start() {
    const ok = await requestSensorPermission();
    if (!ok) { setPageState("nopermission"); return; }
    startSensors();
    await acquireWakeLock();
    setPageState("off");
    connect();
  }

  el.start.addEventListener("click", start);
  el.retry.addEventListener("click", start);
  el.hapticTest.addEventListener("click", (e) => { e.stopPropagation(); tick(); });
})();
