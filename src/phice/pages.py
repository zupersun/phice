"""The pages the Mac serves on loopback: setup, diagnosis, panel, calibration.

Markup and the few lines of script that drive it. No design lives here --
the panel and the calibration screen load stylesheets the user owns, and
their scripts publish numbers and attributes rather than colours or sizes.
Separated from the server because a page is not a request handler, and
because together they were past this project's own file length limit.
"""
from __future__ import annotations

import io

import qrcode
import qrcode.image.svg as qrsvg


def qr_svg(data: str) -> str:
    q = qrcode.QRCode(box_size=8, border=2, error_correction=qrcode.constants.ERROR_CORRECT_M)
    q.add_data(data)
    q.make(fit=True)
    buf = io.BytesIO()
    q.make_image(image_factory=qrsvg.SvgPathImage).save(buf)
    svg = buf.getvalue().decode("utf-8")
    return svg[svg.index("<svg"):]


SETUP_CSS = """
body{font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:28px;
     background:#0b0f14;color:#e8eef5}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:0 0 6px}
.cols{display:flex;flex-wrap:wrap;gap:28px;margin-top:18px}
.card{background:#121820;border:1px solid #222c37;border-radius:14px;padding:18px;max-width:330px}
.card svg{width:230px;height:230px;background:#fff;border-radius:10px;padding:8px}
code{background:#1a2230;padding:2px 6px;border-radius:5px;font-size:13px;word-break:break-all}
ol{padding-left:18px;color:#9fb3c8}li{margin:6px 0}
.muted{color:#6b7a8c;font-size:13px}
.alt{margin-top:12px;padding-top:10px;border-top:1px solid #222c37;font-size:12px}
.alt b{color:#9fb3c8}
"""


def _alt_block(url: str | None, what: str) -> str:
    """The .local equivalent, as a note. It is stabler across DHCP renewals but
    needs mDNS, which many networks block, so it is not the primary path."""
    if not url:
        return ""
    return f"""
      <p class="muted alt">Stable alternative for this {what}, if your network
         resolves <code>.local</code> names:<br><code>{url}</code></p>"""


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
  <p class="code-hint">Enter this on your phone</p>
</div>

<div class="card">
  <div class="url" id="url">\u2014</div>
  <button id="copy">Copy link</button>
  <button id="newcode">New code</button>
</div>

<div class="card">
  <div class="row"><span class="dot" id="d-acc"></span>
    <span class="what">Can move the cursor</span><span class="val" id="v-acc">?</span></div>
  <div class="row"><span class="dot" id="d-conn"></span>
    <span class="what">Phone connected</span><span class="val" id="v-conn">?</span></div>
  <div class="row"><span class="dot" id="d-ptr"></span>
    <span class="what">Pointer</span><span class="val" id="v-ptr">?</span></div>
  <button id="grant">Grant permission\u2026</button>
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
    document.getElementById("sub").textContent =
      d.connected ? "Connected to " + (d.device_name || "your phone")
                  : "Waiting for your phone";
    const acc = document.getElementById("v-acc");
    acc.textContent = d.accessibility ? "granted" : "not granted";
    dot(document.getElementById("d-acc"), d.accessibility ? "ok" : "bad");
    document.getElementById("grant").hidden = !!d.accessibility;
    document.getElementById("v-conn").textContent = d.connected ? "yes" : "no";
    dot(document.getElementById("d-conn"), d.connected ? "ok" : "warn");
    document.getElementById("v-ptr").textContent = d.phase;
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

<div id="target"></div>

<div id="hud">
  <span id="task">Getting ready\u2026</span>
  <span id="hint"></span>
  <span id="bar"><i></i></span>
</div>

<div id="done">
  <div>
    <h1>Calibration finished</h1>
    <p id="summary">Measured from your own trials.</p>
    <div id="results"></div>
    <button id="apply">Use these settings</button>
    <button id="again" class="secondary">Run it again</button>
  </div>
</div>

<script>
const body = document.body, target = document.getElementById("target");
const HINTS = {
  still: "Hold the phone still. Do not try to correct the cursor.",
  step: "Move the cursor onto the target and hold it there.",
  sweep: "Sweep to it as fast as you can, then settle."
};

function show(s) {
  if (s.done) {
    body.dataset.done = "1";
    render(s.fitted || {});
    return;
  }
  delete body.dataset.done;
  body.dataset.kind = s.kind;
  body.dataset.inside = s.inside ? "1" : "0";
  // Only numbers cross this line; calibrate.css decides what they look like.
  target.style.setProperty("--tx", s.x);
  target.style.setProperty("--ty", s.y);
  target.style.setProperty("--tr", s.radius);
  body.style.setProperty("--progress", s.total ? s.index / s.total : 0);
  document.getElementById("task").textContent =
    "Trial " + (s.index + 1) + " of " + s.total;
  document.getElementById("hint").textContent = HINTS[s.kind] || "";
}

function render(fitted) {
  const lines = [];
  for (const [k, v] of Object.entries(fitted)) {
    if (k === "evidence" || k === "samples") continue;
    lines.push(k + ": " + (typeof v === "object" ? JSON.stringify(v) : v));
  }
  for (const [k, v] of Object.entries(fitted.evidence || {})) lines.push("  " + k + ": " + v);
  document.getElementById("results").textContent =
    lines.join("\n") || "Not enough usable trials. Try again and follow each target.";
  document.getElementById("apply").hidden = !!fitted.error || !lines.length;
}

async function poll() {
  try {
    const r = await fetch("/calibrate/state", { cache: "no-store" });
    const s = await r.json();
    if (s.running) show(s);
  } catch (e) { /* the app is restarting; the next tick catches up */ }
}
document.getElementById("apply").onclick = async () => {
  const r = await fetch("/calibrate/apply");
  const out = await r.json();
  document.getElementById("summary").textContent =
    out.ok ? "Saved. Your pointer now uses these." : ("Could not save: " + (out.error || ""));
};
document.getElementById("again").onclick = async () => {
  await fetch("/calibrate/start");
  delete body.dataset.done;
};
poll();
setInterval(poll, 120);
</script>
"""

def check_html(ca_url: str, pair_url: str) -> str:
    """Self-diagnosing page, served over plain HTTP so it always loads.

    It probes an ungated asset on the TLS port with an <img>. That load can
    only succeed if the phone already trusts the local CA, which turns "is the
    certificate installed?" from a question into an answer.
    """
    origin = pair_url.split("/?", 1)[0]
    probe = f"{origin}/assets/apple-touch-icon.png"
    return f"""<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Phice check</title>
<style>{SETUP_CSS}
.big{{font-size:19px;font-weight:700;margin:14px 0 6px}}
.ok{{color:#4ade80}} .bad{{color:#ff5a5f}}
a.btn{{display:block;text-align:center;background:#3ea6ff;color:#04121f;font-weight:700;
      padding:15px;border-radius:12px;text-decoration:none;margin:14px 0}}
a.btn2{{background:transparent;color:#9fb3c8;border:1px solid #232c37}}
</style>
<div class="card" style="max-width:520px;margin:0 auto">
<h1>Phice</h1>
<div id="out"><p class="muted">Checking whether this phone trusts your Mac&hellip;</p></div>
</div>
<script>
var out = document.getElementById("out");
var done = false;
function verdict(ok) {{
  if (done) return; done = true;
  out.innerHTML = ok
    ? '<p class="big ok">Certificate is trusted.</p>'
      + '<p class="muted">Step 1 is complete. Open Phice below, or scan the second QR '
      + 'code on your Mac.</p>'
      + '<a class="btn" href="{pair_url}">Open Phice</a>'
    : '<p class="big bad">Certificate is not trusted yet.</p>'
      + '<p class="muted">This is why the pairing link warns you and then shows a black '
      + 'screen. Install the profile, then <b>turn it on</b> &mdash; installing alone is '
      + 'not enough.</p>'
      + '<a class="btn" href="{ca_url}">1 &middot; Download the profile</a>'
      + '<p class="muted">2 &middot; Settings &rsaquo; <b>Profile Downloaded</b> &rsaquo; Install.<br>'
      + '3 &middot; Settings &rsaquo; General &rsaquo; About &rsaquo; <b>Certificate Trust '
      + 'Settings</b> &rsaquo; turn <b>Phice Local CA</b> on.</p>'
      + '<a class="btn btn2" href="/check">Check again</a>';
}}
var img = new Image();
img.onload = function () {{ verdict(true); }};
img.onerror = function () {{ verdict(false); }};
img.src = "{probe}?t=" + Date.now();
setTimeout(function () {{ verdict(false); }}, 8000);
</script>"""


def setup_html(ca_url: str, pair_url: str, show_ca: bool,
               alt_ca_url: str | None = None, alt_pair_url: str | None = None) -> str:
    ca_card = "" if not show_ca else f"""
    <div class="card">
      <h2>1 · Trust the certificate (once)</h2>
      {qr_svg(ca_url)}
      <ol>
        <li>Point the iPhone camera at this code and tap the banner.</li>
        <li>Safari says <b>This website is trying to download a configuration
            profile</b> &rsaquo; <b>Allow</b>, then <b>Close</b>.</li>
        <li>Settings &rsaquo; <b>Profile Downloaded</b> (near the top) &rsaquo;
            <b>Install</b>, enter your passcode, <b>Install</b> again.</li>
        <li>Settings &rsaquo; General &rsaquo; About &rsaquo; scroll to
            <b>Certificate Trust Settings</b> &rsaquo; turn <b>Phice Local CA</b> on.</li>
      </ol>
      <p class="muted"><b>Do this first.</b> Step 2 shows a black screen until it is done.</p>
      <p class="muted"><code>{ca_url}</code></p>
      {_alt_block(alt_ca_url, "certificate")}
    </div>"""
    return f"""<!doctype html><meta charset="utf-8"><title>Phice setup</title>
<style>{SETUP_CSS}</style>
<h1>Phice setup</h1>
<p class="muted">Keep this page open on the Mac and use the iPhone camera.</p>
<div class="cols">{ca_card}
  <div class="card">
    <h2>{'2' if show_ca else '1'} · Pair the phone</h2>
    {qr_svg(pair_url)}
    <ol>
      <li>Scan and open. Tap <b>Start</b>, allow motion access.</li>
      <li>Optional: Share &rsaquo; Add to Home Screen, open it from there,
          then scan this code again from inside it.</li>
    </ol>
    <p class="muted">Valid for 10 minutes. Reload this page for a fresh code.<br>
    <code>{pair_url}</code></p>
    {_alt_block(alt_pair_url, "pairing link")}
  </div>
</div>"""
