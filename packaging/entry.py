"""Entry point for the frozen Phice.app bundle.

Double-clicking the app must start the menu bar, not print CLI help, so the
default argv is `run`. Arguments still pass through when the executable is
invoked from a terminal or by the launch agent.
"""
import multiprocessing
import sys

from phice.cli import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    argv = sys.argv[1:] or ["run"]
    sys.exit(main(argv))
