#!/usr/bin/env bash
# Publish a downloadable release: ./scripts/release.sh [vX.Y.Z]
#
# Built here and not in CI on purpose. The Accessibility grant keys on the
# bundle's designated requirement, so every release has to be signed with the
# one self-signed certificate every existing user's grant is already bound to
# (packaging/create-signing-identity.sh). That certificate lives in this Mac's
# login keychain and copying it into CI secrets would be a second copy of the
# only key that must not be lost. CI proves the tests pass; this ships.
#
# The asset is named Phice.dmg with no version in it, because that is what makes
#   https://github.com/zupersun/phice/releases/latest/download/Phice.dmg
# a permanent link. Renaming it per release breaks the download button in the
# README for every version after this one.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*CFBundleShortVersionString": "\([^"]*\)".*/\1/p' packaging/phice.spec)"
TAG="${1:-v$VERSION}"

[ "$TAG" = "v$VERSION" ] || {
  echo "tag $TAG does not match the bundle's version $VERSION."
  echo "A release whose app reports a different version in Get Info is a support"
  echo "ticket waiting to happen. Edit CFBundleShortVersionString/CFBundleVersion"
  echo "in packaging/phice.spec first."; exit 1; }

git diff --quiet && git diff --cached --quiet \
  || { echo "working tree is dirty; commit first so the tag names what shipped"; exit 1; }

git fetch --quiet origin
git branch -r --contains HEAD | grep -q . \
  || { echo "HEAD is not pushed; the tag would point at a commit GitHub does not have"; exit 1; }

gh release view "$TAG" >/dev/null 2>&1 \
  && { echo "release $TAG already exists; bump the version or delete it first"; exit 1; }

./packaging/build.sh
./packaging/make-dmg.sh

echo "==> publishing $TAG"
gh release create "$TAG" dist/Phice.dmg \
  --target "$(git rev-parse HEAD)" \
  --title "Phice $VERSION" \
  --generate-notes \
  --notes "$(cat <<'NOTES'
**[Download Phice.dmg](https://github.com/zupersun/phice/releases/latest/download/Phice.dmg)** — macOS 13 or later, Apple silicon.

Open the image, drag **Phice** to Applications, and launch it from there.

Phice is signed, but not notarized by Apple, so the first launch is refused:
open **System Settings › Privacy & Security**, scroll to the message about
Phice, and click **Open Anyway**. Then grant Accessibility when it asks — that
permission is what lets it move the cursor.

The phone needs nothing installed: open https://phice.vercel.app/app in Safari
and type the six-character code the Mac window shows.
NOTES
)"

echo "==> the permanent download link now resolves:"
curl -sIL -o /dev/null -w '    %{http_code}  %{url_effective}\n' \
  https://github.com/zupersun/phice/releases/latest/download/Phice.dmg
