/* Phice hosted client.
 *
 * Pairs by short code through the signaling letterbox, then talks to the Mac
 * over a direct WebRTC DataChannel. Contains no colours, sizes or labels: the
 * layout and the entire stylesheet are pushed from the Mac.
 */
(() => {
  "use strict";

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

    const offerRes = await fetch(`/api/offer?code=${encodeURIComponent(code)}`);
    if (!offerRes.ok) {
      fail("That code was not found. Codes expire after five minutes — check your Mac for a fresh one.");
      return;
    }
    const offer = await offerRes.json();
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

  function wireChannel(channel) {
    state.channel = channel;
    channel.addEventListener("open", () => {
      el.body.dataset.link = "ok";
      // Pairing already happened through the signaling code, so this hello exists
      // only to tell the Mac what this phone can do. Haptics have been guessed at
      // twice; the Mac logs this instead.
      channel.send(JSON.stringify({ t: "hello", ver: 1, name: "iPhone", caps: hapticCaps() }));
      setScreen("start");
    });
    channel.addEventListener("close", () => fail("The Mac closed the connection."));
    channel.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.t === "layout") renderLayout(msg);
      else if (msg.t === "theme") el.theme.textContent = msg.css;
      else if (msg.t === "state") applyState(msg);
    });
  }

  function applyState(msg) {
    // data-state drives everything visual, including the status LED, entirely from
    // the theme. Do NOT set --recenter-progress here: the browser interpolates it
    // itself from the data-state change via @property, and writing it per message
    // restarts the transition ~50 times a second and stutters.
    if (msg.phase) el.body.dataset.state = msg.phase;
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
    if (state.channel && state.channel.readyState === "open") {
      state.channel.send(JSON.stringify({ t: "hello", ver: 1, name: "iPhone",
                                          caps: hapticCaps() + "," + state.perm }));
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
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(() => send(false), 1000 / 60);

    // Attaching a listener proves nothing: permission can be refused and the
    // events simply never arrive. The Mac then times the pointer out a second
    // after it is switched on, which reads as "it turns itself off".
    setTimeout(() => {
      if (state.orientation) return;
      clearInterval(state.timer);
      state.timer = null;
      if (state.channel && state.channel.readyState === "open") {
        state.channel.send(JSON.stringify({ t: "hello", ver: 1, name: "iPhone",
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
    if (!ch || ch.readyState !== "open") return;
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

  document.getElementById("btn-pair").addEventListener("click", () => {
    const code = (el.code.value || "").toUpperCase().trim();
    if (!/^[A-Z2-9]{6}$/.test(code)) { el.code.focus(); return; }
    localStorage.setItem("phice.code", code);
    pair(code).catch((e) => fail(String(e)));
  });
  document.getElementById("btn-start").addEventListener("click", () => {
    startSensors().catch(() => fail("Motion access was denied. Allow it in Settings › Apps › Safari › Motion & Orientation Access."));
  });
  document.getElementById("btn-retry").addEventListener("click", () => setScreen("pair"));

  el.code.value = localStorage.getItem("phice.code") || "";
  setScreen("pair");
})();
