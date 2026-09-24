"""The status line is decided by a pure function so it can be pinned here.

rumps is imported at module level by menubar.py; that is fine on macOS, which is
the only place the suite runs.
"""
from phice.menubar import describe


def _status(**kw) -> dict:
    s = dict(connected=False, device_name="", phase="disconnected", accessibility=True,
             enabled=True, pair_code="ABC234", error="", pairing_error="")
    s.update(kw)
    return s


def test_permission_comes_before_everything():
    assert describe(_status(accessibility=False, pairing_error="x")) == (
        "warn", "Accessibility permission needed")


def test_an_unreachable_letterbox_is_named_not_called_a_config_error():
    assert describe(_status(pairing_error="POST /api/offer failed")) == (
        "warn", "Can't reach the pairing service")


def test_the_ordinary_states():
    assert describe(_status()) == ("disconnected", "No phone connected")
    assert describe(_status(connected=True, device_name="iPhone", phase="on")) == (
        "on", "iPhone · pointer ON")
    assert describe(_status(connected=True, phase="off")) == ("off", "Phone · pointer off")
