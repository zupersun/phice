"""Local certificate authority and server certificate.

Safari only exposes motion sensors on secure pages, so the page must be served
over HTTPS. We mint a local CA once (the user trusts it on the iPhone one time)
and re-issue the server certificate whenever the host's addresses change.
"""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import ipaddress
import json
import shutil
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


class CertError(RuntimeError):
    """Raised when a certificate cannot be obtained."""


CA_DAYS = 3650
SERVER_DAYS = 820  # iOS rejects user-trusted leaf certs valid for more than 825 days
RENEW_WITHIN_DAYS = 30


def local_hostname() -> str:
    try:
        out = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True,
                             timeout=5)
        name = out.stdout.strip()
        if name:
            return name
    except (OSError, subprocess.SubprocessError):
        pass
    return socket.gethostname().split(".")[0] or "localhost"


def local_ipv4s() -> list[str]:
    """Non-loopback IPv4 addresses currently configured on this Mac."""
    addrs: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("192.0.2.1", 9))  # TEST-NET-1: no packets are sent
            addrs.add(s.getsockname()[0])
        finally:
            s.close()
    except OSError:
        pass
    return sorted(a for a in addrs if not a.startswith("127."))


def san_names(host: str) -> list[str]:
    return [f"{host}.local", host, "localhost"]


@dataclass(frozen=True)
class CertPaths:
    ca_key: Path
    ca_crt: Path
    server_key: Path
    server_crt: Path

    @classmethod
    def under(cls, d: Path) -> CertPaths:
        return cls(d / "ca.key", d / "ca.crt", d / "server.key", d / "server.crt")


def _write_private(path: Path, key) -> None:
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                       serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))
    path.chmod(0o600)


def _write_cert(path: Path, cert: x509.Certificate) -> None:
    path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    path.chmod(0o644)


def ensure_ca(paths: CertPaths, host: str) -> x509.Certificate:
    if paths.ca_key.exists() and paths.ca_crt.exists():
        return x509.load_pem_x509_certificate(paths.ca_crt.read_bytes())
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Phice Local CA ({host})"),
                      x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Phice")])
    now = dt.datetime.now(dt.UTC)
    cert = (x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=CA_DAYS))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=False, content_commitment=False,
                                         key_encipherment=False, data_encipherment=False,
                                         key_agreement=False, key_cert_sign=True, crl_sign=True,
                                         encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .sign(key, hashes.SHA256()))
    paths.ca_key.parent.mkdir(parents=True, exist_ok=True)
    _write_private(paths.ca_key, key)
    _write_cert(paths.ca_crt, cert)
    return cert


def server_cert_is_current(paths: CertPaths, host: str, ips: list[str]) -> bool:
    if not (paths.server_crt.exists() and paths.server_key.exists()):
        return False
    try:
        cert = x509.load_pem_x509_certificate(paths.server_crt.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    except Exception:
        return False
    if cert.not_valid_after_utc - dt.datetime.now(dt.UTC) < dt.timedelta(days=RENEW_WITHIN_DAYS):
        return False
    have_dns = set(san.get_values_for_type(x509.DNSName))
    have_ip = {str(i) for i in san.get_values_for_type(x509.IPAddress)}
    return set(san_names(host)) <= have_dns and set(ips) <= have_ip


def ensure_server_cert(paths: CertPaths, host: str, ips: list[str] | None = None) -> bool:
    """Create or renew the leaf certificate. Returns True if it was (re)issued."""
    ips = local_ipv4s() if ips is None else ips
    ensure_ca(paths, host)
    if server_cert_is_current(paths, host, ips):
        return False
    ca_key = serialization.load_pem_private_key(paths.ca_key.read_bytes(), password=None)
    ca_cert = x509.load_pem_x509_certificate(paths.ca_crt.read_bytes())
    key = ec.generate_private_key(ec.SECP256R1())
    alt: list[x509.GeneralName] = [x509.DNSName(n) for n in san_names(host)]
    alt += [x509.IPAddress(ipaddress.ip_address(a)) for a in [*ips, "127.0.0.1"]]
    now = dt.datetime.now(dt.UTC)
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"{host}.local")]))
            .issuer_name(ca_cert.subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=SERVER_DAYS))
            .add_extension(x509.SubjectAlternativeName(alt), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([x509.ExtendedKeyUsageOID.SERVER_AUTH]),
                           critical=False)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            # RFC 5280 requires an AKI on issued certificates; OpenSSL 3.x strict
            # verification rejects the chain without it.
            .add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(
                    ca_cert.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value),
                critical=False)
            .sign(ca_key, hashes.SHA256()))
    _write_private(paths.server_key, key)
    _write_cert(paths.server_crt, cert)
    return True


def ca_der(paths: CertPaths) -> bytes:
    """DER bytes, which is what Safari wants for a downloadable profile."""
    return x509.load_pem_x509_certificate(paths.ca_crt.read_bytes()).public_bytes(
        serialization.Encoding.DER)


def ca_mobileconfig(paths: CertPaths) -> bytes:
    """Wrap the CA in an Apple configuration profile.

    Modern iOS does not offer to install a bare .crt download: Safari saves it
    to Files and nothing happens. A .mobileconfig served as
    application/x-apple-aspen-config triggers the "install this profile" flow
    instead. The UUIDs are derived from the certificate fingerprint so that
    re-downloading replaces the profile rather than stacking duplicates.
    """
    der = ca_der(paths)
    fp = hashlib.sha256(der).hexdigest()

    def _uuid(suffix: str) -> str:
        h = hashlib.sha256((fp + suffix).encode()).hexdigest()
        return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}".upper()

    b64 = base64.b64encode(der).decode()
    payload = "\n".join(b64[i:i + 52] for i in range(0, len(b64), 52))
    cert = x509.load_pem_x509_certificate(paths.ca_crt.read_bytes())
    cn = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>com.phice.ca</string>
      <key>PayloadUUID</key><string>{_uuid("payload")}</string>
      <key>PayloadDisplayName</key><string>{cn}</string>
      <key>PayloadDescription</key><string>Lets this iPhone trust the Phice server on your Mac.</string>
      <key>PayloadCertificateFileName</key><string>PhiceCA.crt</string>
      <key>PayloadContent</key>
      <data>
{payload}
      </data>
    </dict>
  </array>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>com.phice.profile</string>
  <key>PayloadUUID</key><string>{_uuid("profile")}</string>
  <key>PayloadDisplayName</key><string>Phice</string>
  <key>PayloadDescription</key><string>Certificate authority for Phice.</string>
  <key>PayloadOrganization</key><string>Phice</string>
  <key>PayloadRemovalDisallowed</key><false/>
</dict>
</plist>
""".encode()


# --- tailscale -------------------------------------------------------------

TAILSCALE_BINS = ("/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "tailscale")


def tailscale_bin() -> str | None:
    """First usable tailscale CLI: the GUI app bundles one, Homebrew installs one."""
    for candidate in TAILSCALE_BINS:
        path = candidate if "/" in candidate else shutil.which(candidate)
        if path and Path(path).exists():
            return path
    return None


def tailscale_dns_name() -> str | None:
    """This Mac's MagicDNS name, e.g. 'mymac.tail1234.ts.net', or None."""
    binary = tailscale_bin()
    if not binary:
        return None
    try:
        out = subprocess.run([binary, "status", "--json"], capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return None
        name = json.loads(out.stdout).get("Self", {}).get("DNSName", "")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    name = name.rstrip(".")
    return name or None


def ensure_tailscale_cert(paths: CertPaths, name: str) -> bool:
    """Mint or renew a real Let's Encrypt certificate for the tailnet name.

    Needs HTTPS enabled for the tailnet (admin console > DNS > HTTPS
    Certificates). Returns True if a certificate was written.
    """
    binary = tailscale_bin()
    if not binary:
        raise CertError("tailscale is not installed")
    if _cert_covers(paths.server_crt, name):
        return False
    paths.server_crt.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([binary, "cert", "--cert-file", str(paths.server_crt),
                        "--key-file", str(paths.server_key), name],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise CertError(f"tailscale cert failed: {(r.stderr or r.stdout).strip()[:300]}")
    paths.server_key.chmod(0o600)
    return True


def _cert_covers(crt: Path, name: str) -> bool:
    """True if an existing certificate already names `name` and is not expiring."""
    if not crt.exists():
        return False
    try:
        cert = x509.load_pem_x509_certificate(crt.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    except Exception:
        return False
    if cert.not_valid_after_utc - dt.datetime.now(dt.UTC) < dt.timedelta(days=RENEW_WITHIN_DAYS):
        return False
    return name in set(san.get_values_for_type(x509.DNSName))
