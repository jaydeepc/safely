#!/bin/bash
# Builds Shhlock for Mac (the menu-bar app that fills logins in any browser) and installs it in
# /Applications. Run again after pulling new code. Undo: scripts/install-mac-app.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Shhlock.app"
BUNDLE_ID="com.codecrackjd.shhlock.mac"

if [[ "${1:-}" == "--uninstall" ]]; then
  osascript -e 'tell application "Shhlock" to quit' >/dev/null 2>&1 || true
  rm -rf "$APP"
  echo "Shhlock for Mac removed."
  exit 0
fi

echo "▸ Building…"
(cd "$ROOT/core" && swift build -c release --product ShhlockMac 2>&1 | grep -E "error|Compiling|Build" | tail -3)

osascript -e 'tell application "Shhlock" to quit' >/dev/null 2>&1 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/core/.build/release/ShhlockMac" "$APP/Contents/MacOS/Shhlock"

# icon
if [[ -f "$ROOT/design/app-icon.png" ]]; then
  ICONSET="$(mktemp -d)/Shhlock.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/design/app-icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/design/app-icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Shhlock.icns" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Shhlock</string>
  <key>CFBundleDisplayName</key><string>Shhlock</string>
  <key>CFBundleExecutable</key><string>Shhlock</string>
  <key>CFBundleIconFile</key><string>Shhlock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Shhlock talks to your Shhlock Key over Bluetooth to fill your logins.</string>
  <key>NSAppleEventsUsageDescription</key><string>Shhlock reads the address of the page you are signing in to.</string>
</dict></plist>
PLIST

# Ad-hoc signature by default. `--sign` uses your Apple Development identity (asks for keychain access once),
# which keeps the Accessibility permission across rebuilds.
if [[ "${1:-}" == "--sign" ]] && IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')" && [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

open "$APP"
cat <<DONE

Installed $APP and started it. Look for the padlock in the menu bar.
  1. macOS asks whether Shhlock may use Bluetooth → Allow.
  2. Choose "Set up Shhlock…" from the menu → allow Accessibility (System Settings opens; toggle Shhlock on).
  3. Open Shhlock on your phone, then click "Pair with my key" and confirm the code on both.
Start at login: System Settings → General → Login Items → add Shhlock.
DONE
