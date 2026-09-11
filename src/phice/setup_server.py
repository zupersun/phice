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
                 ca_mobileconfig: Callable[[], bytes] | None = None):
        self.port = port
        self._ca_der = ca_der
        self._ca_mobileconfig = ca_mobileconfig
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
                elif path == "/help":
                    ca_url = outer._urls()[0]
                    body = (f"<!doctype html><meta charset=utf-8><title>Phice</title>"
                            f"<style>{SETUP_CSS}</style><h1>Install the Phice certificate</h1>"
                            f"<ol><li>Tap <a href='{ca_url}'>{ca_url}</a></li>"
                            f"<li>Allow the download, then install it in Settings.</li>"
                            f"<li>Settings &rsaquo; General &rsaquo; About &rsaquo; Certificate Trust "
                            f"Settings &rsaquo; enable Phice Local CA.</li></ol>")
                    self._send(200, body.encode(), "text/html; charset=utf-8")
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
