import datetime as dt
import subprocess

import pytest
from cryptography import x509

from phice.certs import (
    CertPaths,
    ca_der,
    ensure_ca,
    ensure_server_cert,
    local_hostname,
    san_names,
    server_cert_is_current,
)
from phice.pairing import PairingManager


def test_ca_is_created_once_and_reused(tmp_path):
    p = CertPaths.under(tmp_path)
    ca1 = ensure_ca(p, "mac")
    assert p.ca_key.stat().st_mode & 0o777 == 0o600
    ca2 = ensure_ca(p, "mac")
    assert ca1.serial_number == ca2.serial_number
    assert "Phice Local CA (mac)" in ca1.subject.rfc4514_string()
    bc = ca1.extensions.get_extension_for_class(x509.BasicConstraints).value
    assert bc.ca is True


def test_server_cert_has_expected_sans_and_is_signed_by_ca(tmp_path):
    p = CertPaths.under(tmp_path)
    assert ensure_server_cert(p, "mac", ["192.168.1.5"]) is True
    cert = x509.load_pem_x509_certificate(p.server_crt.read_bytes())
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert set(san_names("mac")) <= set(san.get_values_for_type(x509.DNSName))
    assert {"192.168.1.5", "127.0.0.1"} <= {str(i) for i in san.get_values_for_type(x509.IPAddress)}
    ca = x509.load_pem_x509_certificate(p.ca_crt.read_bytes())
    assert cert.issuer == ca.subject
    lifetime = cert.not_valid_after_utc - cert.not_valid_before_utc
    assert lifetime < dt.timedelta(days=825)


def test_server_cert_reissued_when_ip_changes_but_ca_is_stable(tmp_path):
    p = CertPaths.under(tmp_path)
    ensure_server_cert(p, "mac", ["192.168.1.5"])
    ca_before = p.ca_crt.read_bytes()
    assert ensure_server_cert(p, "mac", ["192.168.1.5"]) is False
    assert ensure_server_cert(p, "mac", ["10.0.0.9"]) is True
    assert p.ca_crt.read_bytes() == ca_before
    assert server_cert_is_current(p, "mac", ["10.0.0.9"])
    assert not server_cert_is_current(p, "other-mac", ["10.0.0.9"])


def test_ca_der_is_der(tmp_path):
    p = CertPaths.under(tmp_path)
    ensure_ca(p, "mac")
    assert ca_der(p)[:1] == b"\x30"


def test_local_hostname_is_nonempty():
    assert local_hostname()


def test_pairing_flow(tmp_path):
    now = [1000.0]
    m = PairingManager(tmp_path / "devices.json", clock=lambda: now[0])
    assert m.redeem_pairing_token("nope", "iPhone") is None
    tok = m.mint_pairing_token()
    assert m.redeem_pairing_token("wrong-token", "iPhone") is None
    dev = m.redeem_pairing_token(tok, "iPhone")
    assert dev and m.check_device_token(dev)
    assert m.redeem_pairing_token(tok, "iPhone") is None  # single use
    assert m.device_count() == 1


def test_pairing_token_expires(tmp_path):
    now = [1000.0]
    m = PairingManager(tmp_path / "devices.json", clock=lambda: now[0])
    tok = m.mint_pairing_token()
    now[0] += 601
    assert m.redeem_pairing_token(tok, "iPhone") is None


def test_unknown_device_token_rejected_and_revoke(tmp_path):
    m = PairingManager(tmp_path / "devices.json")
    tok = m.mint_pairing_token()
    dev = m.redeem_pairing_token(tok, "iPhone")
    assert not m.check_device_token("a" * 43)
    assert m.path.stat().st_mode & 0o777 == 0o600
    m.revoke_all()
    assert not m.check_device_token(dev)
    assert m.device_count() == 0


def test_device_token_never_stored_in_plaintext(tmp_path):
    m = PairingManager(tmp_path / "devices.json")
    dev = m.redeem_pairing_token(m.mint_pairing_token(), "iPhone")
    assert dev not in m.path.read_text()


def test_pairing_token_is_shared_between_processes(tmp_path):
    """`phice pair-token` runs in a different process from the menu-bar app."""
    cli = PairingManager(tmp_path / "devices.json")
    app = PairingManager(tmp_path / "devices.json")
    token = cli.mint_pairing_token()
    assert app.redeem_pairing_token(token, "iPhone")
    assert app.pending_path.exists() is False


def test_pending_token_is_never_stored_in_plaintext(tmp_path):
    m = PairingManager(tmp_path / "devices.json")
    tok = m.mint_pairing_token()
    assert tok not in m.pending_path.read_text()
    assert m.pending_path.stat().st_mode & 0o777 == 0o600


def _self_signed(name: str) -> bytes:
    """A certificate carrying `name` in its SAN, standing in for a real tailnet one."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    key = ec.generate_private_key(ec.SECP256R1())
    now = dt.datetime.now(dt.UTC)
    n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    cert = (x509.CertificateBuilder().subject_name(n).issuer_name(n)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(minutes=5))
            .not_valid_after(now + dt.timedelta(days=90))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
            .sign(key, hashes.SHA256()))
    return cert.public_bytes(serialization.Encoding.PEM)


def test_tailscale_helpers_are_absent_without_tailscale(monkeypatch, tmp_path):
    from phice import certs
    monkeypatch.setattr(certs, "TAILSCALE_BINS", ("/nonexistent/tailscale",))
    monkeypatch.setattr(certs.shutil, "which", lambda _n: None)
    assert certs.tailscale_bin() is None
    assert certs.tailscale_dns_name() is None
    with pytest.raises(certs.CertError, match="not installed"):
        certs.ensure_tailscale_cert(CertPaths.under(tmp_path), "x.ts.net")


def test_tailscale_cert_is_reused_until_it_nears_expiry(tmp_path, monkeypatch):
    """A tailnet certificate is a real 90-day Let's Encrypt one. Re-minting on
    every start would hit the ACME rate limit, so a covering cert is reused."""
    from phice import certs
    cp = CertPaths.under(tmp_path)
    cp.server_crt.parent.mkdir(parents=True, exist_ok=True)
    name = "mac.tail1234.ts.net"
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        cp.server_crt.write_bytes(_self_signed(name))
        cp.server_key.write_bytes(b"key")
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(certs, "tailscale_bin", lambda: "/usr/bin/true")
    monkeypatch.setattr(certs.subprocess, "run", fake_run)

    assert certs.ensure_tailscale_cert(cp, name) is True
    assert len(calls) == 1 and calls[0][1] == "cert" and calls[0][-1] == name
    assert certs.ensure_tailscale_cert(cp, name) is False  # reused, not re-minted
    assert len(calls) == 1
    # A different tailnet name is not covered by it.
    assert certs.ensure_tailscale_cert(cp, "other.tail1234.ts.net") is True
    assert len(calls) == 2
