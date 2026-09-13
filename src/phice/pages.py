"""The pages the Mac serves on loopback: setup, diagnosis, panel, calibration.

Markup and the few lines of script that drive it. No design lives here --
the panel and the calibration screen load stylesheets the user owns, and
their scripts publish numbers and attributes rather than colours or sizes.
Separated from the server because a page is not a request handler; the
two long documents live in templates.py for the same reason.
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
