"""Draw packaging/AppIcon.icns from the mark, for the spec to hand PyInstaller.

Generated rather than committed, for the same reason the menu bar's images are:
the icon is the logo, and a binary copy of it is one more thing to keep in step.
Drawn once at a thousand pixels and resampled by sips, which is what every other
size in an iconset is anyway.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from phice.icons import app_icon  # noqa: E402

# Every size iconutil expects, as (pixels, file name).
SIZES = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
         (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
         (512, "512x512"), (1024, "512x512@2x")]


def main(out: Path) -> int:
    work = out.with_suffix(".iconset")
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    full = work / "icon_512x512@2x.png"
    full.write_bytes(app_icon(1024))
    for px, name in SIZES:
        dst = work / f"icon_{name}.png"
        if dst == full:
            continue
        subprocess.run(["sips", "-z", str(px), str(px), str(full), "--out", str(dst)],
                       check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(work), "-o", str(out)], check=True)
    shutil.rmtree(work, ignore_errors=True)
    print(f"==> drew {out} ({out.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1] if len(sys.argv) > 1
                               else Path(__file__).parent / "AppIcon.icns")))
