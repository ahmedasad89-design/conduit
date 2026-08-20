#!/usr/bin/env bash
# Build + bundle Conduit as a double-clickable .app.
#
#   ./build.sh            debug build, opens the app
#   ./build.sh release    release build, leaves ./Conduit.app in place
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "→ Compiling ($CONFIG)…"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
else
    swift build
    BIN_DIR="$(swift build --show-bin-path)"
fi
EXEC="$BIN_DIR/Conduit"

if [[ ! -x "$EXEC" ]]; then
    echo "✗ Compiled executable not found at $EXEC" >&2
    exit 1
fi

APP="$ROOT/Conduit.app"
echo "→ Bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXEC" "$APP/Contents/MacOS/Conduit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Regenerate the icon if the generator is newer than the .icns, then bundle it.
if [[ ! -f "$ROOT/Resources/Conduit.icns" || "$ROOT/Tools/makeicon.swift" -nt "$ROOT/Resources/Conduit.icns" ]]; then
    echo "→ Drawing the app icon"
    swift "$ROOT/Tools/makeicon.swift" "$ROOT/Resources" >/dev/null
    iconutil -c icns "$ROOT/Resources/Conduit.iconset" -o "$ROOT/Resources/Conduit.icns"
fi
cp "$ROOT/Resources/Conduit.icns" "$APP/Contents/Resources/Conduit.icns"

# Ad-hoc signature with the hardened runtime so Gatekeeper will launch a
# locally built app cleanly. Locally built bundles carry no quarantine xattr,
# so no right-click-Open dance is needed.
codesign --force --options runtime --sign - "$APP" >/dev/null
codesign --verify --strict "$APP" || { echo "✗ signature failed to verify" >&2; exit 1; }

echo "✓ Built $APP"
echo ""
echo "Run:  open '$APP'"
