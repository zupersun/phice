"""The status line is decided by a pure function so it can be pinned here.

rumps is imported at module level by menubar.py; that is fine on macOS, which is
the only place the suite runs.
"""
import itertools

import pytest

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


def test_launching_phice_again_brings_its_window_back():
    """Opening an app that is already running starts no second process: macOS
    activates the one that is running and sends its delegate this message. The
    delegate rumps installs does not implement it, so every launch after the
    first did nothing at all -- clicking the Dock icon, Spotlight, Launchpad and
    `open -a` alike -- which left a running Phice whose window had been closed
    with no way back except a menu bar icon the notch can swallow.

    Installed onto rumps' own delegate class, since rumps builds that instance
    and hands it to AppKit itself; the throwaway class here proves the mechanism
    without mutating the real one.
    """
    objc = pytest.importorskip("objc")
    from Foundation import NSObject

    from phice.menubar import REOPEN_SEL, install_reopen_handler

    class ReopenProbe(NSObject):
        pass

    opened = []
    assert install_reopen_handler(lambda: opened.append(1), cls=ReopenProbe) is True
    assert ReopenProbe.instancesRespondToSelector_(REOPEN_SEL)
    delegate = ReopenProbe.alloc().init()
    assert delegate.applicationShouldHandleReopen_hasVisibleWindows_(None, False) is True
    assert opened == [1], "the window is asked for"
    # Asked for again even when a window is already up: the one-shot mailbox
    # makes that idempotent, and refusing would strand a window on another space.
    delegate.applicationShouldHandleReopen_hasVisibleWindows_(None, True)
    assert opened == [1, 1]
    # Installing twice must not raise: a selector cannot be added to a class
    # twice, and the menu bar is built again on every reload.
    assert install_reopen_handler(lambda: opened.append(2), cls=ReopenProbe) is True
    assert objc is not None
