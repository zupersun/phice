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

echo "==> verifying the bundle can actually resolve its resources"
# Runs the real binary rather than asserting a PyInstaller layout: resource_dir()
# reads sys._MEIPASS, not a fixed path, so this is immune to layout changes and
# also catches the case where Paths.ensure() cannot find defaults/assets/.
T="$(mktemp -d)"
dist/Phice.app/Contents/MacOS/Phice --config-dir "$T" paths >/dev/null \
  || { echo "bundle cannot resolve its packaged resources"; rm -rf "$T"; exit 1; }
for f in pointer.json layout.json theme.css assets/logo.svg; do
  test -e "$T/$f" || { echo "MISSING from bundle: $f"; rm -rf "$T"; exit 1; }
done
rm -rf "$T"

echo "==> built $(du -sh dist/Phice.app | cut -f1)  dist/Phice.app" \
     "($(lipo -archs dist/Phice.app/Contents/MacOS/Phice 2>/dev/null || echo unknown))"
echo "    open it with:  open dist/Phice.app"
