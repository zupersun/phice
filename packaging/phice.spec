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

hiddenimports = collect_submodules("rumps") + [
    "Quartz", "AppKit", "Foundation", "ApplicationServices", "objc",
]

a = Analysis(
    ["entry.py"],
    pathex=["../src"],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy.testing", "pytest"],
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
    bundle_identifier="com.phice.app",   # stable: the Accessibility grant keys on this
    info_plist={
        "LSUIElement": True,             # menu bar only, no Dock icon
        "CFBundleName": "Phice",
        "CFBundleDisplayName": "Phice",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "0.2.0",
        "NSHumanReadableCopyright": "",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
    },
)
