"""Plain-HTTP helper server: CA download, setup page with QR codes, debug hooks.

This is deliberately *not* TLS: the iPhone has to fetch the CA certificate
before it can trust anything we serve over HTTPS.
"""
from __future__ import annotations

import io
import json
import logging
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import qrcode
import qrcode.image.svg as qrsvg

log = logging.getLogger("phice.setup")


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
  if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t);
} catch (e) { /* private browsing, etc.: falls back to system appearance */ }
</script>
<div class="topbar">
  <h1>Phice</h1>
  <button id="theme">Theme</button>
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

function themeMode() {
  try {
    const t = localStorage.getItem("phice-theme");
    return (t === "light" || t === "dark") ? t : "system";
  } catch (e) { return "system"; }
}
function applyTheme(mode) {
  if (mode === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", mode);
  try {
    if (mode === "system") localStorage.removeItem("phice-theme");
    else localStorage.setItem("phice-theme", mode);
  } catch (e) { /* private browsing, etc.: the choice just won't stick */ }
  document.getElementById("theme").textContent =
    "Theme: " + mode.charAt(0).toUpperCase() + mode.slice(1);
}
document.getElementById("theme").onclick = () => {
  const order = ["system", "light", "dark"];
  applyTheme(order[(order.indexOf(themeMode()) + 1) % order.length]);
};
applyTheme(themeMode());

refresh();
setInterval(refresh, 1000);
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


class SetupServer:
    """Threaded HTTP server. Loopback-only routes are enforced per request."""

    def __init__(self, port: int, ca_der: Callable[[], bytes],
                 urls: Callable[[], tuple[str, str, bool, str | None, str | None]],
                 debug_cursor: Callable[[], dict] | None = None,
                 ca_mobileconfig: Callable[[], bytes] | None = None,
                 grant_accessibility: Callable[[], bool] | None = None,
                 pair_code: Callable[[], str] | None = None,
                 panel_css: Callable[[], bytes] | None = None,
                 new_code: Callable[[], None] | None = None,
                 signaling_url: Callable[[], str] | None = None):
        self.port = port
        self._ca_der = ca_der
        self._ca_mobileconfig = ca_mobileconfig
        self._grant_accessibility = grant_accessibility
        self._pair_code = pair_code
        self._panel_css = panel_css
        self._new_code = new_code
        self._signaling_url = signaling_url
        self._urls = urls
        self._debug_cursor = debug_cursor
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def _handler_class(self):
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):  # noqa: A003
                log.debug("setup %s", fmt % args)

            def _send(self, status: int, body: bytes, ctype: str, extra: dict | None = None):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def _is_local(self) -> bool:
                return self.client_address[0] in ("127.0.0.1", "::1")

            def do_POST(self):  # noqa: N802
                self.do_GET()

            def do_GET(self):  # noqa: N802
                path = self.path.split("?", 1)[0]
                if path == "/ca.mobileconfig":
                    if outer._ca_mobileconfig is None:
                        self._send(404, b"not found", "text/plain")
                        return
                    self._send(200, outer._ca_mobileconfig(), "application/x-apple-aspen-config",
                               {"Content-Disposition": 'attachment; filename="Phice.mobileconfig"'})
                elif path == "/ca.crt":
                    self._send(200, outer._ca_der(), "application/x-x509-ca-cert",
                               {"Content-Disposition": 'attachment; filename="PhiceCA.crt"'})
                elif path in ("/", "/setup"):
                    if not self._is_local():
                        self._send(403, b"setup page is available on the Mac only", "text/plain")
                        return
                    ca_url, pair_url, show_ca, alt_ca, alt_pair = outer._urls()
                    self._send(200,
                               setup_html(ca_url, pair_url, show_ca, alt_ca, alt_pair).encode(),
                               "text/html; charset=utf-8")
                elif path == "/pair" and self._is_local():
                    code = outer._pair_code() if outer._pair_code else ""
                    url = outer._signaling_url() if outer._signaling_url else ""
                    body = (f"<!doctype html><meta charset=utf-8><title>Phice pairing</title>"
                            f"<style>{SETUP_CSS}"
                            f".code{{font-size:64px;letter-spacing:16px;text-align:center;"
                            f"margin:26px 0 18px;color:#3ea6ff;font-weight:700}}</style>"
                            f"<div class='card' style='max-width:460px;margin:0 auto'>"
                            f"<h1>Pair your phone</h1>"
                            f"<p class='muted'>Open <b>{url}/app</b> on your iPhone and "
                            f"enter this code. Nothing is installed on the phone.</p>"
                            f"<div class='code'>{code or '······'}</div>"
                            f"<p class='muted'>Single use, and it expires after five "
                            f"minutes. Reload for the current one.</p></div>")
                    self._send(200, body.encode(), "text/html; charset=utf-8")
                elif path == "/panel" and self._is_local():
                    self._send(200, PANEL_HTML.encode(), "text/html; charset=utf-8")
                elif path == "/panel.css" and self._is_local():
                    # Served from the config directory so the user can restyle it,
                    # exactly like the phone's theme.
                    css = outer._panel_css() if outer._panel_css else b""
                    self._send(200, css, "text/css; charset=utf-8")
                elif path == "/debug/newcode" and outer._new_code and self._is_local():
                    outer._new_code()
                    self._send(200, b'{"ok":true}', "application/json")
                elif path == "/check":
                    ca_url, pair_url, *_ = outer._urls()  # one call: each mints a token
                    self._send(200, check_html(ca_url, pair_url).encode(),
                               "text/html; charset=utf-8")
                elif path == "/help":
                    ca_url = outer._urls()[0]
                    body = (f"<!doctype html><meta charset=utf-8><title>Phice</title>"
                            f"<style>{SETUP_CSS}</style><h1>Install the Phice certificate</h1>"
                            f"<ol><li>Tap <a href='{ca_url}'>{ca_url}</a></li>"
                            f"<li>Allow the download, then install it in Settings.</li>"
                            f"<li>Settings &rsaquo; General &rsaquo; About &rsaquo; Certificate Trust "
                            f"Settings &rsaquo; enable Phice Local CA.</li></ol>")
                    self._send(200, body.encode(), "text/html; charset=utf-8")
                elif path == "/debug/grant" and outer._grant_accessibility and self._is_local():
                    # Prompting from this process is what makes macOS add *this*
                    # binary to the Accessibility list; asking from a terminal
                    # would add the terminal instead.
                    ok = outer._grant_accessibility()
                    self._send(200, json.dumps({"accessibility": ok}).encode(), "application/json")
                elif path == "/debug/cursor" and outer._debug_cursor and self._is_local():
                    self._send(200, json.dumps(outer._debug_cursor()).encode(), "application/json")
                else:
                    self._send(404, b"not found", "text/plain")

        return Handler

    def start(self) -> int:
        self._httpd = ThreadingHTTPServer(("0.0.0.0", self.port), self._handler_class())
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True,
                                        name="phice-setup")
        self._thread.start()
        return self.port

    def stop(self) -> None:
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
