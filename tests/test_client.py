"""The phone client, actually executed.

For most of this project there were 200-odd tests and not one of them ran
web/app/app.js. Every bug the phone has shown -- an invisible Start button, a
theme that never arrived, a channel that opened before anyone was listening --
lived in the one file nothing could reach. This runs it against a stub DOM.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests" / "client" / "run.mjs"


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_the_phone_client_runs_and_renders():
    r = subprocess.run(["node", str(RUNNER)], capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "all good" in r.stdout
