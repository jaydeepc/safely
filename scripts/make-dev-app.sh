#!/bin/bash
# Wraps a command line tool from core/ in a minimal .app so macOS can grant it Bluetooth access.
# (A bare CLI inherits the privacy identity of whatever launched it; an .app started with `open` is its own.)
#
#   scripts/make-dev-app.sh safely-simphone "Safely SimPhone"
set -euo pipefail
TOOL="$1"; NAME="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$NAME.app"

(cd "$ROOT/core" && swift build -c release --product "$TOOL" >/dev/null)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/core/.build/release/$TOOL" "$APP/Contents/MacOS/$TOOL"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.safely.dev.$TOOL</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$TOOL</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Safely talks to your Safely Key over Bluetooth.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
