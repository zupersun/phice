"""Loopback HTTP: the control panel, the calibration screen and the debug hooks.

Bound to 127.0.0.1 and nothing else. The phone never talks to this -- its page
is hosted and the pointer arrives over a data channel -- so there is no reason
for anything on the LAN to be able to reach it.
"""
from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .templates import CALIBRATE_HTML, PANEL_HTML

log = logging.getLogger("phice.control")

HOST = "127.0.0.1"
DOCUMENTS = {"/panel": PANEL_HTML, "/calibrate": CALIBRATE_HTML}


class ControlServer:
    """Three kinds of route, each a table the runtime fills in:

    - ``pages``: path -> bytes, served as CSS. The panel and calibration
      stylesheets, read from the config folder so the user can restyle them.
    - ``actions``: path -> dict, answered as JSON. A bare ``None`` return is
      reported as ``{"ok": true}``, so a plain method can be wired directly.
    - ``settings``: path -> fn(value) -> bool, taking ``?v=`` and answering
      200 or 400 with the verdict.
    """

    def __init__(self, port: int, *,
                 pages: dict[str, Callable[[], bytes]] | None = None,
                 actions: dict[str, Callable[[], dict | None]] | None = None,
                 settings: dict[str, Callable[[str], bool]] | None = None):
        self.port = port
        self._pages = pages or {}
        self._actions = actions or {}
        self._settings = settings or {}
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def address(self) -> tuple[str, int]:
        return (HOST, self.port)

    def _handler_class(self):
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):  # noqa: A003
                log.debug("control %s", fmt % args)

            def _send(self, status: int, body: bytes, ctype: str) -> None:
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def _json(self, status: int, obj) -> None:
                self._send(status, json.dumps(obj).encode(), "application/json")

            def do_POST(self):  # noqa: N802
                self.do_GET()

            def do_GET(self):  # noqa: N802
                url = urlparse(self.path)
                path = url.path
                if path in DOCUMENTS:
                    self._send(200, DOCUMENTS[path].encode(), "text/html; charset=utf-8")
                elif path in outer._pages:
                    self._send(200, outer._pages[path](), "text/css; charset=utf-8")
                elif path in outer._actions:
                    result = outer._actions[path]()
                    self._json(200, {"ok": True} if result is None else result)
                elif path in outer._settings:
                    value = parse_qs(url.query).get("v", [""])[0]
                    ok = outer._settings[path](value)
                    self._json(200 if ok else 400, {"ok": ok, "v": value})
                else:
                    self._send(404, b"not found", "text/plain")

        return Handler

    def start(self) -> int:
        self._httpd = ThreadingHTTPServer((HOST, self.port), self._handler_class())
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True,
                                        name="phice-control")
        self._thread.start()
        return self.port

    def stop(self) -> None:
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
