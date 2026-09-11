import ssl

import pytest

from phice.certs import CertPaths, ensure_server_cert
from phice.config import PointerConfig, load_layout
from phice.cursor_backend import FakeCursor
from phice.engine import PointerEngine
from phice.pairing import PairingManager
from phice.paths import Paths
from phice.server import PhiceServer, ServerState


@pytest.fixture
def rig(tmp_path):
    """A configured server (not yet started) plus its fake cursor and paths."""
    paths = Paths(tmp_path / "cfg")
    paths.ensure()
    ensure_server_cert(CertPaths.under(paths.certs), "testmac", ["127.0.0.1"])
    layout = load_layout(paths.layout_json)
    cursor = FakeCursor()
    engine = PointerEngine(PointerConfig(), cursor)
    engine.set_roles(layout.roles())
    state = ServerState(paths=paths, pairing=PairingManager(paths.devices_json), engine=engine,
                        layout=layout, config=PointerConfig())
    server = PhiceServer(state, "127.0.0.1", 0, "testmac")
    return type("Rig", (), {"paths": paths, "cursor": cursor, "engine": engine, "state": state,
                            "server": server})


@pytest.fixture
def client_ssl(rig):
    ctx = ssl.create_default_context(cafile=str(CertPaths.under(rig.paths.certs).ca_crt))
    return ctx
