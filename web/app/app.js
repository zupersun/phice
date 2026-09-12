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
    orientation: null,
    rate: [0, 0, 0],
    gravity: [0, 0, 9.8],
    timer: null,
    motionTimes: [],
    hz: 0,
  };

  const setState = (s) => { el.body.dataset.state = s; };

  // ---------- pairing ----------

  async function pair(code) {
    setState("connecting");
    // STUN alone only discovers addresses. When both peers are behind symmetric
    // NAT -- a phone on carrier NAT talking to a Mac on a campus network -- neither
    // can reach the other, and a relay is the only thing that works. The Mac must
    // be given the same list, or the two sides gather incompatible candidates.
    const pc = new RTCPeerConnection({
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" },
        {
          urls: [
            "turn:openrelay.metered.ca:80",
            "turn:openrelay.metered.ca:443",
            "turn:openrelay.metered.ca:443?transport=tcp",
          ],
          username: "openrelayproject",
          credential: "openrelayproject",
        },
      ],
    });
    state.pc = pc;

    pc.addEventListener("datachannel", (ev) => wireChannel(ev.channel));
    pc.addEventListener("connectionstatechange", () => {
      if (["failed", "closed", "disconnected"].includes(pc.connectionState)) {
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
    setState("failed");
  }

  // ---------- channel ----------

  function wireChannel(channel) {
    state.channel = channel;
    channel.addEventListener("open", () => {
      // Pairing already happened through the signaling code, so this hello exists
      // only to tell the Mac what this phone can do. Haptics have been guessed at
      // twice; the Mac logs this instead.
      channel.send(JSON.stringify({ t: "hello", ver: 1, name: "iPhone", caps: hapticCaps() }));
      setState("start");
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
    if (msg.ui) { state.haptics = !!msg.ui.haptics; }
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
      if (navigator.vibrate) navigator.vibrate(8);
    }
    state.pressed.set(id, pressed);
    b.el.dataset.pressed = pressed ? "1" : "0";
    send(true);
  }

  function setScrollThumb(b, clientY) {
    const r = b.el.getBoundingClientRect();
    if (!r.height) return;
    const pos = Math.min(1, Math.max(0, (clientY - r.top) / r.height));
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
        if (b && b.role === "scroll") b.el.style.removeProperty("--scroll-pos");
        setPressed(rec.id, false);
      }
    }
  };
  el.pad.addEventListener("touchend", endTouch, { passive: false });
  el.pad.addEventListener("touchcancel", endTouch, { passive: false });

  // ---------- sensors ----------

  async function startSensors() {
    const D = window.DeviceOrientationEvent, M = window.DeviceMotionEvent;
    // requestPermission must be called from a user gesture, which is why this
    // hangs off the Start button rather than running on load.
    if (D && typeof D.requestPermission === "function") await D.requestPermission();
    if (M && typeof M.requestPermission === "function") await M.requestPermission();

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

    el.body.dataset.state = "on";
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(() => send(false), 1000 / 60);
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
  document.getElementById("btn-retry").addEventListener("click", () => setState("pair"));

  el.code.value = localStorage.getItem("phice.code") || "";
  setState("pair");
})();
