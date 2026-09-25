"""The status line is decided by a pure function so it can be pinned here.

rumps is imported at module level by menubar.py; that is fine on macOS, which is
the only place the suite runs.
"""
import itertools

from phice.menubar import ICONS, TITLES, describe


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


def test_a_working_pointer_outranks_a_stale_letterbox_error():
    assert describe(_status(connected=True, phase="on", pairing_error="x")) == (
        "on", "Phone · pointer ON")


def test_the_ordinary_states():
    assert describe(_status()) == ("disconnected", "No phone connected")
    assert describe(_status(connected=True, device_name="iPhone", phase="on")) == (
        "on", "iPhone · pointer ON")
    assert describe(_status(connected=True, phase="off")) == ("off", "Phone · pointer off")


def test_every_combination_names_an_icon_in_the_table():
    """The names `describe` chooses and the names `_set_icon` looks up live in two
    different places; an unknown name would raise KeyError inside the refresh timer
    and kill the status tick. Tie them together here rather than by adding a phase
    or a flag and only finding out at runtime."""
    for accessibility, connected, phase, pairing_error in itertools.product(
        (True, False), (True, False), ("disconnected", "off", "on", "hold", "held"), ("", "x")
    ):
        s = _status(accessibility=accessibility, connected=connected, phase=phase,
                     pairing_error=pairing_error)
        icon, _ = describe(s)
        assert icon in ICONS and icon in TITLES, (accessibility, connected, phase, pairing_error)
