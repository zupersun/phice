import datetime as dt

import pytest
from cryptography import x509

from phice.certs import (CertPaths, ca_der, ensure_ca, ensure_server_cert, local_hostname,
                            san_names, server_cert_is_current)
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
