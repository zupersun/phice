# PyInstaller spec for Phice.app
#   uv run pyinstaller packaging/phice.spec --noconfirm
# Produces dist/Phice.app
from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

# defaults/ and web/ must land at the bundle root, because paths.resource_dir()
# returns sys._MEIPASS and looks for them directly beneath it.
datas = [
    ("../src/phice/defaults", "defaults"),
    ("../src/phice/web", "web"),
]

# collect_submodules is required per framework: listing a bare name pulls in the
# top-level module but not its submodules or bindings, and ApplicationServices was
# silently missing from the bundle as a result -- which made the Accessibility check
# raise ImportError and report "not granted" forever.
hiddenimports = collect_submodules("rumps")
# ApplicationServices/__init__ imports CoreText, HIServices, Quartz and objc
# *inside a function*, so static analysis never sees them. HIServices is the
# one that actually provides AXIsProcessTrustedWithOptions.
for _fw in ("objc", "Foundation", "AppKit", "Quartz", "ApplicationServices",
            "CoreText", "HIServices", "CoreFoundation", "WebKit"):
    try:
        hiddenimports += collect_submodules(_fw)
    except Exception:
        hiddenimports.append(_fw)

a = Analysis(
    ["entry.py"],
    pathex=["../src"],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="Phice",
    debug=False,
    strip=False,
    upx=False,
    console=False,
)
coll = COLLECT(
    exe, a.binaries, a.zipfiles, a.datas,
    strip=False, upx=False, name="Phice",
)
app = BUNDLE(
    coll,
    name="Phice.app",
    icon=None,
    bundle_identifier="com.phice.app",   # part of the designated requirement; never change it
    info_plist={
        "LSUIElement": True,             # menu bar only, no Dock icon
        "CFBundleName": "Phice",
        "CFBundleDisplayName": "Phice",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "0.2.0",
        "NSHumanReadableCopyright": "",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        # The panel window is WKWebView loading 127.0.0.1 over plain HTTP.
        # App Transport Security blocks that without this exemption, and the
        # only symptom is a blank window.
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    },
)
