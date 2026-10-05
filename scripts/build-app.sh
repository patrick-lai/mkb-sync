#!/usr/bin/env bash
# Builds dist/MKB Sync.app (universal arm64 + x86_64) and dist/MKBSync.zip.
#
#   scripts/build-app.sh                 # ad-hoc signed
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   ARCHS="arm64" scripts/build-app.sh   # single architecture (faster)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-arm64 x86_64}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="$ROOT/dist/MKB Sync.app"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

echo "==> Building ($ARCHS)"
swift build -c release --product MKBSync "${arch_flags[@]}"
BIN_DIR="$(swift build -c release --product MKBSync "${arch_flags[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MKBSync" "$APP/Contents/MacOS/MKBSync"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with identity: $IDENTITY"
sign_flags=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then sign_flags+=(--options runtime --timestamp); fi
codesign "${sign_flags[@]}" "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Zipping"
(cd "$ROOT/dist" && rm -f MKBSync.zip && ditto -c -k --keepParent "MKB Sync.app" MKBSync.zip)
echo "Done: $APP"
