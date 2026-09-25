"""The two long documents: the control panel and the calibration screen.

Markup only, held apart from pages.py because four hundred lines of HTML
sitting in a module of Python functions makes both harder to read, and
because together they were past this project's own file length limit.
Neither carries design -- both load stylesheets the user owns, and their
scripts publish numbers and attributes rather than colours or sizes.
"""
from __future__ import annotations

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

<div class="card" id="pair-card">
  <div class="code" id="code">\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7</div>
  <div class="code-life" aria-hidden="true"><i></i></div>
  <p class="code-hint" id="code-hint">Renewing\u2026</p>
</div>

<div class="card">
  <div class="url" id="url">\u2014</div>
  <button id="copy">Copy link</button>
  <button id="newcode">New code</button>
</div>

<div class="card">
  <div class="row"><span class="dot" id="d-acc"></span>
    <span class="what">Permissions</span><span class="val" id="v-acc">?</span></div>
  <div class="row"><span class="dot" id="d-conn"></span>
    <span class="what">Connection</span><span class="val" id="v-conn">?</span></div>
  <div class="row"><span class="dot" id="d-ptr"></span>
    <span class="what">Pointer</span><span class="val" id="v-ptr">?</span></div>
  <p class="note" id="stale" hidden>The phone is showing a cached copy of the
     page. Close the tab and open the link again.</p>
  <button id="grant">Grant permission\u2026</button>
</div>

<div class="card">
  <b>Grip</b>
  <p class="lede">One-handed moves the buttons into thumb reach and puts power at
     the top, out of the way of an accidental press.</p>
  <div class="seg" id="grip" role="radiogroup" aria-label="Layout" tabindex="0">
    <span class="knob" aria-hidden="true"></span>
    <span class="stop" role="radio" data-v="standard" aria-label="Two hands"></span>
    <span class="stop" role="radio" data-v="one-handed" aria-label="One hand"></span>
  </div>
  <div class="seg-labels" aria-hidden="true">
    <span>Two hands</span><span>One hand</span>
  </div>
</div>

<div class="card">
  <b>Pointer feel</b>
  <p class="lede">Point the phone at a few dots and Phice measures how much of
     your screen one degree of wrist actually covers. Under a minute, no cursor
     involved, and nothing is saved until you approve it.</p>
  <p class="when" id="calibrated">Not calibrated yet</p>
  <button id="calibrate" class="primary">Calibrate pointer\u2026</button>
</div>

<div class="card">
  <b>How to connect</b>
  <ol>
    <li>Open the link above on your iPhone.</li>
    <li>Type the code, then tap <b>Start</b> and allow motion access.</li>
    <li>Point at the cursor and press any button to begin.</li>
  </ol>
  <p class="note">Closing this window leaves Phice running in the menu bar.</p>
</div>

<script>
function dot(el, cls) { el.className = "dot" + (cls ? " " + cls : ""); }
async function refresh() {
  try {
    const r = await fetch("/debug/cursor", { cache: "no-store" });
    const d = await r.json();
    document.getElementById("code").textContent = d.pair_code || "\u00b7\u00b7\u00b7\u00b7\u00b7\u00b7";
    document.getElementById("url").textContent = d.phone_url || "\u2014";
    // Which of four situations the code is in, and how much life it has left
    // (0..1). Only a number and an attribute cross this line; panel.css draws.
    const pairing = d.connected ? "connected"
                  : d.pairing_error ? "error"
                  : d.offer_ready ? "ready" : "renewing";
    document.body.dataset.pairing = pairing;
    document.body.style.setProperty("--code-life",
                    (pairing === "ready" ? (Number(d.code_life) || 0) : 0).toFixed(3));
    document.getElementById("code-hint").textContent = {
      connected: "Connected. The code stays valid for next time.",
      error: "Can\u2019t reach the pairing service. Phice keeps trying.",
      ready: "Enter this on your phone. It renews itself.",
      renewing: "Renewing\u2026",
    }[pairing];
    document.getElementById("sub").textContent =
      d.connected ? "Connected to " + (d.device_name || "your phone")
                  : "Waiting for your phone";
    const acc = document.getElementById("v-acc");
    acc.textContent = d.accessibility ? "granted" : "not granted";
    dot(document.getElementById("d-acc"), d.accessibility ? "ok" : "bad");
    document.getElementById("grant").hidden = !!d.accessibility;
    document.getElementById("v-conn").textContent = d.connected ? "on" : "off";
    dot(document.getElementById("d-conn"), d.connected ? "ok" : "warn");
    document.getElementById("v-ptr").textContent = d.phase;
    document.getElementById("stale").hidden = !d.client_stale;
    // Never move the knob under a finger that is dragging it.
    if (!gripDragging) {
      // "custom" means layout.json rather than a preset; show it as standard so
      // the knob has somewhere to sit rather than vanishing off the track.
      const shown = GRIPS.includes(d.layout) ? d.layout : "standard";
      if (shown !== grip.dataset.v) applyGrip(shown);
    }
    document.getElementById("calibrated").textContent =
      d.calibrated ? "Last calibrated " + d.calibrated : "Not calibrated yet";
    // Never yank the knob out from under a finger that is dragging it.
    if (!dragging && d.appearance && d.appearance !== seg.dataset.v) applyTheme(d.appearance);
    dot(document.getElementById("d-ptr"),
        d.phase === "on" ? "ok" : d.phase === "off" ? "warn" : "");
  } catch (e) { /* the app is restarting; the next tick will catch up */ }
}
document.getElementById("copy").onclick = () =>
  navigator.clipboard.writeText(document.getElementById("url").textContent);
document.getElementById("newcode").onclick = async () => {
  await fetch("/debug/newcode", { method: "POST" }); refresh();
};
document.getElementById("grant").onclick = async () => {
  await fetch("/debug/grant"); refresh();
};
// The grip switch, same contract as appearance: the script sets an attribute and
// posts the choice; what that looks like is decided in panel.css.
const GRIPS = ["standard", "one-handed"];
const grip = document.getElementById("grip");
let gripDragging = false;

function applyGrip(name) {
  grip.dataset.v = name;
  for (const s of grip.querySelectorAll(".stop")) {
    s.setAttribute("aria-checked", String(s.dataset.v === name));
  }
}
function gripIndexAt(clientX) {
  const r = grip.getBoundingClientRect();
  if (!r.width) return 0;
  return Math.min(1, Math.max(0, ((clientX - r.left) / r.width) * 2 - 0.5));
}
async function chooseGrip(name) {
  applyGrip(name);
  try { await fetch("/debug/layout?v=" + name); } catch (e) { /* the poll retries */ }
}
grip.addEventListener("pointerdown", (ev) => {
  gripDragging = true;
  grip.dataset.dragging = "1";
  grip.setPointerCapture(ev.pointerId);
  grip.style.setProperty("--knob-drag", gripIndexAt(ev.clientX).toFixed(3));
});
grip.addEventListener("pointermove", (ev) => {
  if (gripDragging) grip.style.setProperty("--knob-drag", gripIndexAt(ev.clientX).toFixed(3));
});
const endGrip = (ev) => {
  if (!gripDragging) return;
  gripDragging = false;
  delete grip.dataset.dragging;
  grip.style.removeProperty("--knob-drag");
  chooseGrip(GRIPS[Math.round(gripIndexAt(ev.clientX))]);
};
grip.addEventListener("pointerup", endGrip);
grip.addEventListener("pointercancel", endGrip);
// A plain click as well: pointer capture inside a WKWebView has surprised this
// project before, and a switch that silently does nothing is worse than one
// that only clicks.
grip.addEventListener("click", (ev) => {
  if (!gripDragging) chooseGrip(GRIPS[Math.round(gripIndexAt(ev.clientX))]);
});
for (const stop of grip.querySelectorAll(".stop")) {
  stop.addEventListener("click", (ev) => { ev.stopPropagation(); chooseGrip(stop.dataset.v); });
}
grip.addEventListener("keydown", (ev) => {
  const i = GRIPS.indexOf(grip.dataset.v || "standard");
  if (ev.key === "ArrowLeft" && i > 0) chooseGrip(GRIPS[i - 1]);
  else if (ev.key === "ArrowRight" && i < GRIPS.length - 1) chooseGrip(GRIPS[i + 1]);
  else return;
  ev.preventDefault();
});

document.getElementById("calibrate").onclick = async () => {
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
