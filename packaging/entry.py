"""Entry point for the frozen Phice.app bundle.

Double-clicking the app must start the menu bar, not print CLI help, so the
default argv is `run`. Arguments still pass through when the executable is
invoked from a terminal or by the launch agent.
"""
import multiprocessing
import sys

from phice.cli import main


def default_argv(argv: list[str]) -> list[str]:
    """Double-clicking passes no arguments and must start the menu bar."""
    return argv[1:] or ["run"]


if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main(default_argv(sys.argv)))
