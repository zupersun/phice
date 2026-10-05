"""The two long documents: the control panel and the calibration screen.

Markup only, held apart from pages.py because four hundred lines of HTML
sitting in a module of Python functions makes both harder to read, and
because together they were past this project's own file length limit. The
panel's Layout card, markup and script, lives in panel_layout.py for the
same reason.
Neither carries design -- both load stylesheets the user owns, and their
scripts publish numbers and attributes rather than colours or sizes.
"""
from __future__ import annotations

from .panel_layout import LAYOUT_CARD, LAYOUT_SCRIPT

PANEL_HTML = """<!doctype html>
<meta charset="utf-8">
<title>Phice</title>
<link rel="stylesheet" href="/panel.css">
<script>
try {
  var t = localStorage.getItem("phice-theme");
  document.documentElement.setAttribute("data-theme", t === "light" ? "light" : "dark");
} catch (e) { /* private browsing, etc.: falls back to system appearance */ }
</script>
<div class="topbar">
  <h1>Phice</h1>
  <div class="appearance">
    <div class="seg" id="seg" role="radiogroup" aria-label="Appearance" tabindex="0">
      <span class="knob" aria-hidden="true"></span>
      <span class="stop" role="radio" data-v="dark" aria-label="Dark"></span>
      <span class="stop" role="radio" data-v="light" aria-label="Light"></span>
    </div>
    <div class="seg-labels" aria-hidden="true">
      <span>Dark</span><span>Light</span>
    </div>
  </div>
</div>
<p class="sub" id="sub">Checking\u2026</p>

<!-- Until a phone connects: only the way in. -->
<div class="screen-pair">
  <div class="card ticket" id="pair-card">
    <div class="stub" id="qr" role="img" aria-label="QR code for the pairing link"></div>
    <div class="body">
      <div class="code" id="code">\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7</div>
      <div class="code-life" aria-hidden="true"><i></i></div>
      <p class="line" id="line">Scan, or enter the code at
        <button id="link" class="text" title="Copy the link">\u2026</button></p>
      <p class="line" id="code-hint">Renewing\u2026</p>
    </div>
  </div>
  <ol class="steps">
    <li>Connect your phone with the code above.</li>
    <li>Tap <b>Start</b> on the phone and allow motion.</li>
    <li>Point the phone at the cursor and tap the power button on its screen
        to begin.</li>
  </ol>
  <div class="card allow" id="allow" hidden>
    <span class="dot bad"></span>
    <span class="what">Allow Phice to move the cursor
      <small>macOS asks once, in Accessibility</small></span>
    <button id="grant" class="primary">Allow</button>
  </div>
</div>

<!-- Once one has: the controls. -->
<div class="screen-live">
  <div class="card">
    <div class="conn">
      <span class="dot" id="d-conn"></span>
      <span class="what"><span id="device">Your phone</span>
        <small>Connected \u00b7 the code stays valid for next time</small></span>
      <span class="code-s" id="code-s">\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7</span>
      <button id="newcode" class="text">New code</button>
    </div>
    <div class="conn-rows">
      <div class="row"><span class="dot" id="d-ptr"></span>
        <span class="what">Pointer</span><span class="val" id="v-ptr">?</span></div>
      <div class="row"><span class="dot" id="d-acc"></span>
        <span class="what">Permissions</span><span class="val" id="v-acc">?</span>
        <button id="grant-live" class="text" hidden>Allow</button></div>
    </div>
    <p class="note" id="stale" hidden>The phone is showing a cached copy of the
       page. Close the tab and open the link again.</p>
  </div>

""" + LAYOUT_CARD + """<div class="card pointer">
    <div class="what"><b>Pointer</b><span class="val" id="calibrated">Not calibrated yet</span></div>
    <button id="calibrate" class="primary">Calibrate pointer</button>
  </div>
  <p class="foot">Closing this window keeps Phice in the menu bar</p>
</div>

<script>
function dot(el, cls) { el.className = "dot" + (cls ? " " + cls : ""); }
const hostOf = (url) => { try { return new URL(url).host; } catch (e) { return url || ""; } };
const link = document.getElementById("link");
let linkUrl = "";
let copiedUntil = 0;
let qrShown = "";

// The QR is the pairing link, drawn by the Mac. Asked for once per code, not
// on every poll; the stylesheet decides its size and colour.
async function drawQR(code) {
  try {
    const r = await fetch("/debug/qr", { cache: "no-store" });
    const q = await r.json();
    if (q.code === code) { document.getElementById("qr").innerHTML = q.svg; qrShown = code; }
  } catch (e) { /* the next poll asks again */ }
}

async function refresh() {
  try {
    const r = await fetch("/debug/cursor", { cache: "no-store" });
    const d = await r.json();
    const code = d.pair_code || "\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7";
    document.getElementById("code").textContent = code;
    document.getElementById("code-s").textContent = code;
    if (d.pair_code && d.pair_code !== qrShown) drawQR(d.pair_code);
    linkUrl = d.phone_url || "";
    if (Date.now() > copiedUntil) link.textContent = hostOf(linkUrl);
    // Which of four situations the code is in, and how much life it has left
    // (0..1). Only a number and an attribute cross this line; panel.css draws,
    // and chooses which of the two screens shows.
    const pairing = d.connected ? "connected"
                  : d.pairing_error ? "error"
                  : d.offer_ready ? "ready" : "renewing";
    document.body.dataset.pairing = pairing;
    document.body.style.setProperty("--code-life",
                    (pairing === "ready" ? (Number(d.code_life) || 0) : 0).toFixed(3));
    document.getElementById("code-hint").textContent = {
      error: "Can\u2019t reach the pairing service. Phice keeps trying.",
      renewing: "Renewing\u2026",
    }[pairing] || "";
    document.getElementById("sub").textContent =
      d.connected ? "Connected to " + (d.device_name || "your phone")
                  : "Waiting for your phone";
    document.getElementById("device").textContent = d.device_name || "Your phone";
    document.getElementById("v-acc").textContent = d.accessibility ? "granted" : "not granted";
    dot(document.getElementById("d-acc"), d.accessibility ? "ok" : "bad");
    document.getElementById("grant-live").hidden = !!d.accessibility;
    document.getElementById("allow").hidden = !!d.accessibility;
    document.getElementById("v-ptr").textContent = d.phase;
    const ptr = d.phase === "on" ? "ok" : d.phase === "off" ? "warn" : "";
    dot(document.getElementById("d-ptr"), ptr);
    dot(document.getElementById("d-conn"), ptr);
    document.getElementById("stale").hidden = !d.client_stale;
    // Never move the knob, or the drawing, under a finger that is dragging it.
    if (!modeDrag) {
      // "custom" means layout.json rather than a preset; show it as the mouse so
      // the knob has somewhere to sit rather than vanishing off the track.
      const shown = LAYOUTS.includes(d.layout) ? d.layout : "standard";
      if (shown !== mode.dataset.v) applyLayout(shown);
    }
    if (!blockDragging && typeof d.block_y === "number") {
      place.style.setProperty("--block-y", d.block_y.toFixed(3));
      mini.setAttribute("aria-valuenow", d.block_y.toFixed(3));
    }
    if (pairing === "connected") delete place.dataset.tried;
    document.getElementById("calibrated").textContent =
      d.calibrated ? "Last calibrated " + d.calibrated : "Not calibrated yet";
    // Never yank the knob out from under a finger that is dragging it.
    if (!dragging && d.appearance && d.appearance !== seg.dataset.v) applyTheme(d.appearance);
  } catch (e) { /* the app is restarting; the next tick will catch up */ }
}
// The address in the sentence copies the link, code included: with Universal
// Clipboard that lands straight in Safari on the phone.
link.onclick = async () => {
  if (!linkUrl) return;
  try { await navigator.clipboard.writeText(linkUrl); } catch (e) { return; }
  copiedUntil = Date.now() + 1200;
  link.textContent = "Copied";
  setTimeout(() => { copiedUntil = 0; link.textContent = hostOf(linkUrl); }, 1200);
};
// Flip to renewing at once and ask often until the offer is up: the poll's
// second was most of what "new code" used to wait for.
let fastUntil = 0;
function fastPoll() {
  fastUntil = Date.now() + 8000;
  const tick = async () => {
    await refresh();
    if (Date.now() < fastUntil && document.body.dataset.pairing === "renewing") setTimeout(tick, 250);
  };
  tick();
}
document.getElementById("newcode").onclick = async () => {
  document.body.dataset.pairing = "renewing";
  await fetch("/debug/newcode", { method: "POST" });
  fastPoll();
};
for (const id of ["grant", "grant-live"]) {
  document.getElementById(id).onclick = async () => { await fetch("/debug/grant"); refresh(); };
}
""" + LAYOUT_SCRIPT + """document.getElementById("calibrate").onclick = async () => {
  // The calibration screen handles pairing itself, so this needs no phone yet.
  await fetch("/calibrate/start");
};

// Appearance: a three stop slider. The Mac owns the value -- the phone follows
// it too -- so this reads from /debug/cursor and writes to /debug/appearance.
// localStorage is only a cache, to place the knob before the first poll lands.
const MODES = ["dark", "light"];
const seg = document.getElementById("seg");
let dragging = false;

function applyTheme(mode) {
  document.documentElement.setAttribute("data-theme", mode);
  seg.dataset.v = mode;
  for (const s of seg.querySelectorAll(".stop")) {
    s.setAttribute("aria-checked", String(s.dataset.v === mode));
  }
  try {
    localStorage.setItem("phice-theme", mode);
  } catch (e) { /* private browsing: the cache just will not stick */ }
}

async function chooseTheme(mode) {
  applyTheme(mode);
  try { await fetch("/debug/appearance?v=" + mode); } catch (e) { /* retried by poll */ }
}

// Where the pointer sits along the track, 0..2. Only a number reaches the CSS;
// what it means is the stylesheet's business.
function indexAt(clientX) {
  const r = seg.getBoundingClientRect();
  if (!r.width) return 0;
  return Math.min(1, Math.max(0, ((clientX - r.left) / r.width) * 2 - 0.5));
}

seg.addEventListener("pointerdown", (ev) => {
  dragging = true;
  seg.dataset.dragging = "1";
  seg.setPointerCapture(ev.pointerId);
  seg.style.setProperty("--knob-drag", indexAt(ev.clientX).toFixed(3));
});
seg.addEventListener("pointermove", (ev) => {
  if (dragging) seg.style.setProperty("--knob-drag", indexAt(ev.clientX).toFixed(3));
});
const endDrag = (ev) => {
  if (!dragging) return;
  dragging = false;
  delete seg.dataset.dragging;
  seg.style.removeProperty("--knob-drag");
  chooseTheme(MODES[Math.round(indexAt(ev.clientX))]);
};
seg.addEventListener("pointerup", endDrag);
seg.addEventListener("pointercancel", endDrag);
seg.addEventListener("keydown", (ev) => {
  const i = MODES.indexOf(seg.dataset.v || "dark");
  if (ev.key === "ArrowLeft" && i > 0) chooseTheme(MODES[i - 1]);
  else if (ev.key === "ArrowRight" && i < MODES.length - 1) chooseTheme(MODES[i + 1]);
  else return;
  ev.preventDefault();
});

try {
  const cached = localStorage.getItem("phice-theme");
  applyTheme(cached === "light" ? "light" : "dark");
} catch (e) { applyTheme("dark"); }

// The first poll has not landed yet. A pulsing full bar is an honest "still
// checking"; the ready state then steps DOWN from it once a code is live,
// rather than the empty-then-fill-up flash of starting from nothing.
document.body.dataset.pairing = "renewing";
refresh();
setInterval(refresh, 1000);

// The window is only as tall as what the page holds. The page measures itself
// whenever its content changes size and tells the Mac, which sizes the window;
// a short trailing wait lets the drawer's spring finish before the window moves.
let sentHeight = 0;
let sizeTimer = 0;
function reportSize() {
  clearTimeout(sizeTimer);
  sizeTimer = setTimeout(() => {
    const h = Math.ceil(document.documentElement.scrollHeight);
    if (h && h !== sentHeight) {
      sentHeight = h;
      fetch("/debug/panel-size?v=" + h).catch(() => {});
    }
  }, 120);
}
new ResizeObserver(reportSize).observe(document.body);
reportSize();
</script>
"""

CALIBRATE_HTML = """<!doctype html>
<meta charset="utf-8">
<title>Calibrate Phice</title>
<link rel="stylesheet" href="/calibrate.css">
<script>
try {
  var th = localStorage.getItem("phice-theme");
  document.documentElement.setAttribute("data-theme", th === "light" ? "light" : "dark");
} catch (e) { /* falls back to the stylesheet's own default */ }
</script>

<div id="target" class="aim"></div>

<div id="intro">
  <div>
    <h1>Point at the dots</h1>
    <p class="lede">There won\u2019t be a cursor. Hold your phone the way you
       normally do. Point your phone at the dots that appear on the screen and
       hold until the rings fill.</p>

    <!-- Shows what is about to happen, on a loop. The animation is entirely in
         calibrate.css; this is only the stage it plays on. -->
    <div id="demo" aria-hidden="true"><span class="aim demo-aim"></span></div>

    <div id="connect">
      <div class="pair">
        <div class="code" id="code">\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7</div>
        <div class="url" id="url"></div>
      </div>
      <p class="status" id="status">Waiting for your phone\u2026</p>
    </div>

    <button id="begin" disabled>Begin</button>
    <button id="skip" class="secondary">Close (Esc)</button>
  </div>
</div>

<div id="hud">
  <span id="step">\u2014</span>
  <span id="task">Getting ready\u2026</span>
  <span id="why"></span>
  <span id="bar"><i></i></span>
  <button id="quit" class="secondary">Stop</button>
</div>

<div id="done">
  <div>
    <h1>Calibration finished</h1>
    <p id="summary">Measured from your own trials.</p>
    <div id="results"></div>
    <button id="apply">Use these settings</button>
    <button id="again" class="secondary">Run it again</button>
    <button id="close" class="secondary">Close</button>
  </div>
</div>

<script>
const body = document.body, target = document.getElementById("target");
function show(s) {
  if (s.done) {
    body.dataset.done = "1";
    render(s.fitted || {});
    return;
  }
  delete body.dataset.done;
  body.dataset.started = s.started ? "1" : "0";
  body.dataset.inside = s.settling ? "1" : "0";
  // Only numbers cross this line; calibrate.css decides what they look like.
  target.style.setProperty("--tx", s.x);
  target.style.setProperty("--ty", s.y);
  // Do not step the ring from the poll: at 120ms that is eight frames a second
  // and looks broken. Tell the browser how long the hold takes and let it
  // interpolate at the display's refresh rate, 60 or 120Hz.
  if (s.settling && !body.dataset.settling) {
    body.dataset.settling = "1";
    target.style.setProperty("--hold-ms", Math.max(0, s.settle_ms - s.held_ms) + "ms");
    requestAnimationFrame(() => target.style.setProperty("--hold", 1));
  } else if (!s.settling && body.dataset.settling) {
    delete body.dataset.settling;
    target.style.setProperty("--hold-ms", "90ms");
    target.style.setProperty("--hold", 0);
  }
  body.style.setProperty("--progress", s.total ? s.index / s.total : 0);
  const ready = !!s.ready;
  document.getElementById("begin").disabled = !ready;
  body.dataset.ready = ready ? "1" : "0";
  document.getElementById("code").textContent = s.pair_code || "\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7";
  document.getElementById("url").textContent = s.phone_url || "";
  document.getElementById("status").textContent =
    !s.connected ? "Waiting for your phone \u2014 open the link above and enter the code"
    : !ready ? "Connected. Press any button on the phone to switch the pointer on."
    : "Ready.";
  document.getElementById("step").textContent = (s.index + 1) + " / " + s.total;
  document.getElementById("task").textContent = s.note || "Point the phone at the dot";
  document.getElementById("why").textContent =
    s.settling ? "Hold it there\u2026" : "Aim, then keep still";
}

function render(fitted) {
  const lines = [];
  for (const [k, v] of Object.entries(fitted)) {
    if (k === "evidence" || k === "samples") continue;
    lines.push(k + ": " + (typeof v === "object" ? JSON.stringify(v) : v));
  }
  for (const [k, v] of Object.entries(fitted.evidence || {})) lines.push("  " + k + ": " + v);
  document.getElementById("results").textContent =
    lines.join("\\n") || "Not enough usable trials. Try again and follow each target.";
  document.getElementById("apply").hidden = !!fitted.error || !lines.length;
}

let autoBegun = false;
async function poll() {
  try {
    const r = await fetch("/calibrate/state", { cache: "no-store" });
    const s = await r.json();
    if (!s.running) return;
    show(s);
    // Arming the pointer is the moment someone is ready. Making them walk back
    // to the Mac and press Begin as well is a step for its own sake.
    if (!s.started && s.ready && !autoBegun) {
      autoBegun = true;
      await fetch("/calibrate/begin");
    }
  } catch (e) { /* the app is restarting; the next tick catches up */ }
}
document.getElementById("apply").onclick = async () => {
  const r = await fetch("/calibrate/apply");
  const out = await r.json();
  document.getElementById("summary").textContent =
    out.ok ? "Saved. Your pointer now uses these." : ("Could not save: " + (out.error || ""));
  if (!out.ok) return;
  // Nothing left to do here, so leave: fade out, then close. Sitting on a
  // finished screen waiting to be dismissed is a step with no purpose.
  body.dataset.leaving = "1";
  setTimeout(stop, 620);
};
document.getElementById("again").onclick = async () => {
  autoBegun = false;
  await fetch("/calibrate/start");
  delete body.dataset.done;
};
// Borderless and full screen, so there is no title bar to close. Escape and a
// visible button are the only ways out; leaving someone stuck behind a window
// covering their whole display would be unforgivable.
const stop = async () => {
  body.dataset.leaving = "1";          // respond now; the window follows
  try { await fetch("/calibrate/cancel"); } catch (e) { delete body.dataset.leaving; }
};
document.getElementById("quit").onclick = stop;
document.getElementById("close").onclick = stop;
window.addEventListener("keydown", (ev) => { if (ev.key === "Escape") stop(); });
document.getElementById("begin").onclick = async () => {
  await fetch("/calibrate/begin");
  body.dataset.started = "1";
};
document.getElementById("skip").onclick = stop;

poll();
setInterval(poll, 120);
</script>
"""
