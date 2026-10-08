"""The control panel's Layout card: one bar, and a drawer with a small phone.

Markup and script only, spliced into PANEL_HTML by templates.py. Like the rest
of the panel it carries no design: the script sets attributes and publishes
numbers, and panel.css decides what they look like.
"""
from __future__ import annotations

LAYOUT_CARD = """<div class="card">
  <b>Layout</b>
  <div class="mode" id="mode" role="radiogroup" aria-label="Layout" tabindex="0">
    <span class="knob" aria-hidden="true"></span>
    <span class="stop" role="radio" data-v="standard" aria-label="Mouse"></span>
    <span class="stop" role="radio" data-v="thumb-left" aria-label="Left thumb"></span>
    <span class="stop" role="radio" data-v="thumb-centre" aria-label="Centred"></span>
    <span class="stop" role="radio" data-v="thumb-right" aria-label="Right thumb"></span>
  </div>
  <div class="mode-labels" aria-hidden="true">
    <span class="l-mouse">Mouse</span><span class="l-ergo">Ergonomic</span>
    <span class="l-left">Left</span><span class="l-centre">Centre</span>
    <span class="l-right">Right</span>
  </div>
  <div class="reveal"><div class="inner">
    <div class="place" id="place">
      <div class="mini" role="slider" aria-label="Where the controls sit"
           aria-valuemin="0" aria-valuemax="1" aria-valuenow="0.65" tabindex="0">
        <i class="pad-l"></i><i class="pad-r"></i><i class="power"></i>
        <i class="wheel"></i><i class="block"></i>
      </div>
      <div class="aside">
        <p class="hint">Drag the controls to where your thumb rests</p>
        <p class="warn" role="status">Phone not connected</p>
      </div>
    </div>
  </div></div>
</div>

"""

LAYOUT_SCRIPT = """// The layout bar, same contract as appearance: the script sets attributes and
// publishes numbers, and posts the choice; what any of it looks like is decided
// in panel.css. The knob is a third of the track wide. The left third is the
// mouse; the right two thirds hold the three ergonomic places, and crossing
// into them from the mouse lands in the middle first.
const LAYOUTS = ["standard", "thumb-left", "thumb-centre", "thumb-right"];
const ERGO = { "thumb-left": 1 / 2, "thumb-centre": 2 / 3, "thumb-right": 5 / 6 };  // knob centres
const mode = document.getElementById("mode");
const place = document.getElementById("place");
const mini = place.querySelector(".mini");
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
let modeDrag = null;
let blockDragging = false;

function applyLayout(name) {
  mode.dataset.v = name;
  place.dataset.v = name;
  document.body.dataset.layout = name;   // the How to use card draws its phone in it
  mode.classList.toggle("ergo", name !== "standard");
  for (const s of mode.querySelectorAll(".stop")) {
    s.setAttribute("aria-checked", String(s.dataset.v === name));
  }
}
async function chooseLayout(name) {
  applyLayout(name);
  try { await fetch("/debug/layout?v=" + name); } catch (e) { /* the poll retries */ }
}
// The knob's left edge, 0 .. 2/3 of the track, with the pointer at its centre.
function knobAt(clientX) {
  const r = mode.getBoundingClientRect();
  if (!r.width) return 0;
  return clamp((clientX - r.left) / r.width - 1 / 6, 0, 2 / 3);
}
function settle(x, from) {
  const c = x + 1 / 6;
  if (c < 1 / 3) return "standard";
  if (from === "standard") return "thumb-centre";
  let best = "thumb-centre", gap = 9;
  for (const k in ERGO) { const d = Math.abs(ERGO[k] - c); if (d < gap) { gap = d; best = k; } }
  return best;
}
function followKnob(x) {
  mode.style.setProperty("--knob-x", x.toFixed(4));
  mode.classList.toggle("ergo", x + 1 / 6 >= 1 / 3);
}
mode.addEventListener("pointerdown", (ev) => {
  modeDrag = { from: mode.dataset.v || "standard", x: knobAt(ev.clientX) };
  mode.dataset.dragging = "1";
  mode.setPointerCapture(ev.pointerId);
  followKnob(modeDrag.x);
});
mode.addEventListener("pointermove", (ev) => {
  if (modeDrag) { modeDrag.x = knobAt(ev.clientX); followKnob(modeDrag.x); }
});
const endMode = () => {
  if (!modeDrag) return;
  const name = settle(modeDrag.x, modeDrag.from);
  modeDrag = null;
  delete mode.dataset.dragging;
  mode.style.removeProperty("--knob-x");
  chooseLayout(name);
};
mode.addEventListener("pointerup", endMode);
mode.addEventListener("pointercancel", endMode);
mode.addEventListener("keydown", (ev) => {
  const i = LAYOUTS.indexOf(mode.dataset.v || "standard");
  if (ev.key === "ArrowLeft" && i > 0) chooseLayout(LAYOUTS[i - 1]);
  else if (ev.key === "ArrowRight" && i < LAYOUTS.length - 1) chooseLayout(LAYOUTS[i + 1]);
  else return;
  ev.preventDefault();
});

// The little phone: drag the drawing up or down. The number streams to the Mac
// while the finger is down, at most once a frame, and is written once on
// release. With no phone connected nothing is sent and the card says so.
const connected = () => document.body.dataset.pairing === "connected";
let pendingY = null;
function yAt(clientY) {
  const r = mini.getBoundingClientRect();
  return r.height ? clamp((clientY - r.top - 26) / (r.height - 52), 0, 1) : 0;
}
function streamY(y) {
  place.style.setProperty("--block-drag", y.toFixed(3));
  if (!connected()) { place.dataset.tried = "1"; return; }
  if (pendingY === null) {
    requestAnimationFrame(() => {
      const v = pendingY;
      pendingY = null;
      if (v !== null) fetch("/debug/block-drag?v=" + v).catch(() => {});
    });
  }
  pendingY = y.toFixed(3);
}
async function settleY(y) {
  pendingY = null;
  place.style.setProperty("--block-y", y);
  mini.setAttribute("aria-valuenow", y);
  try { await fetch("/debug/block?v=" + y); } catch (e) { /* the poll retries */ }
}
mini.addEventListener("pointerdown", (ev) => {
  blockDragging = true;
  mini.dataset.dragging = "1";
  mini.setPointerCapture(ev.pointerId);
  streamY(yAt(ev.clientY));
});
mini.addEventListener("pointermove", (ev) => { if (blockDragging) streamY(yAt(ev.clientY)); });
const endBlock = (ev) => {
  if (!blockDragging) return;
  blockDragging = false;
  delete mini.dataset.dragging;
  place.style.removeProperty("--block-drag");
  settleY(yAt(ev.clientY).toFixed(3));
};
mini.addEventListener("pointerup", endBlock);
mini.addEventListener("pointercancel", endBlock);
mini.addEventListener("keydown", (ev) => {
  let y = Number(place.style.getPropertyValue("--block-y")) || 0;
  if (ev.key === "ArrowUp") y -= 0.05; else if (ev.key === "ArrowDown") y += 0.05; else return;
  ev.preventDefault();
  settleY(clamp(y, 0, 1).toFixed(3));
});

"""
