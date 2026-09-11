#!/usr/bin/env bash
# Build dist/Phice.app. Run from the repo root: ./packaging/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> tests must pass before shipping a bundle"
uv run pytest -q

echo "==> cleaning previous build"
rm -rf build dist

echo "==> freezing"
uv run pyinstaller packaging/phice.spec --noconfirm --log-level WARN

test -d dist/Phice.app || { echo "build produced no bundle"; exit 1; }

echo "==> verifying packaged resources survived"
# PyInstaller's macOS BUNDLE writes datas under Contents/Resources and
# symlinks Contents/Frameworks/<name> -> ../Resources/<name>.
R="dist/Phice.app/Contents/Resources"
for f in defaults/pointer.json defaults/layout.json defaults/theme.css \
         web/index.html web/app.js; do
  test -f "$R/$f" || { echo "MISSING from bundle: $f"; exit 1; }
done

echo "==> built $(du -sh dist/Phice.app | cut -f1)  dist/Phice.app"
echo "    open it with:  open dist/Phice.app"
