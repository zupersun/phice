"""Plain-HTTP helper server: CA download, setup page with QR codes, debug hooks.

This is deliberately *not* TLS: the iPhone has to fetch the CA certificate
before it can trust anything we serve over HTTPS.
"""
from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .pages import PANEL_HTML, SETUP_CSS, check_html, setup_html

log = logging.getLogger("phice.setup")



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
                 set_appearance: Callable[[str], bool] | None = None,
                 request_panel: Callable[[], None] | None = None,
                 calibrate_html: Callable[[], bytes] | None = None,
                 calibrate_css: Callable[[], bytes] | None = None,
                 calibration_state: Callable[[], dict] | None = None,
                 start_calibration: Callable[[], dict] | None = None,
                 apply_calibration: Callable[[], dict] | None = None,
                 cancel_calibration: Callable[[], dict] | None = None,
                 signaling_url: Callable[[], str] | None = None):
        self.port = port
        self._ca_der = ca_der
        self._ca_mobileconfig = ca_mobileconfig
        self._grant_accessibility = grant_accessibility
        self._pair_code = pair_code
        self._panel_css = panel_css
        self._new_code = new_code
        self._set_appearance = set_appearance
        self._request_panel = request_panel
        self._calibrate_html = calibrate_html
        self._calibrate_css = calibrate_css
        self._calibration_state = calibration_state
        self._start_calibration = start_calibration
        self._apply_calibration = apply_calibration
        self._cancel_calibration = cancel_calibration
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
                elif (path.startswith("/debug/appearance") and outer._set_appearance
                      and self._is_local()):
                    value = parse_qs(urlparse(self.path).query).get("v", [""])[0]
                    ok = outer._set_appearance(value)
                    self._send(200 if ok else 400,
                               json.dumps({"ok": ok, "appearance": value}).encode(),
                               "application/json")
                elif path == "/calibrate" and outer._calibrate_html and self._is_local():
                    self._send(200, outer._calibrate_html(), "text/html; charset=utf-8")
                elif path == "/calibrate.css" and outer._calibrate_css and self._is_local():
                    self._send(200, outer._calibrate_css(), "text/css; charset=utf-8")
                elif path == "/calibrate/state" and outer._calibration_state and self._is_local():
                    self._send(200, json.dumps(outer._calibration_state()).encode(),
                               "application/json")
                elif path == "/calibrate/apply" and outer._apply_calibration and self._is_local():
                    self._send(200, json.dumps(outer._apply_calibration()).encode(),
                               "application/json")
                elif (path == "/calibrate/cancel" and outer._cancel_calibration
                      and self._is_local()):
                    self._send(200, json.dumps(outer._cancel_calibration()).encode(),
                               "application/json")
                elif path == "/calibrate/start" and outer._start_calibration and self._is_local():
                    self._send(200, json.dumps(outer._start_calibration()).encode(),
                               "application/json")
                elif path == "/debug/panel" and outer._request_panel and self._is_local():
                    outer._request_panel()
                    self._send(200, b'{"ok":true}', "application/json")
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
