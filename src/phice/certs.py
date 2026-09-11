"""Local certificate authority and server certificate.

Safari only exposes motion sensors on secure pages, so the page must be served
over HTTPS. We mint a local CA once (the user trusts it on the iPhone one time)
and re-issue the server certificate whenever the host's addresses change.
"""
from __future__ import annotations

import datetime as dt
import ipaddress
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

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
    def under(cls, d: Path) -> "CertPaths":
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
    now = dt.datetime.now(dt.timezone.utc)
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
    if cert.not_valid_after_utc - dt.datetime.now(dt.timezone.utc) < dt.timedelta(days=RENEW_WITHIN_DAYS):
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
    now = dt.datetime.now(dt.timezone.utc)
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"{host}.local")]))
            .issuer_name(ca_cert.subject)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=SERVER_DAYS))
            .add_extension(x509.SubjectAlternativeName(alt), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([x509.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    _write_private(paths.server_key, key)
    _write_cert(paths.server_crt, cert)
    return True


def ca_der(paths: CertPaths) -> bytes:
    """DER bytes, which is what Safari wants for a downloadable profile."""
    return x509.load_pem_x509_certificate(paths.ca_crt.read_bytes()).public_bytes(
        serialization.Encoding.DER)
