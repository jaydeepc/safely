#!/bin/bash
# Builds the Shlok Bluetooth helper and registers it with Chrome (and Brave / Edge / Chromium if present)
# as the native messaging host "app.safely.host". Run again after pulling new code. Undo: scripts/install-host.sh --uninstall
set -euo pipefail

HOST_NAME="app.safely.host"
EXTENSION_ID="mdjogdhejifdjfafpknienahijafaaia"   # fixed by the "key" in extension/manifest.json
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/Safely"
BROWSERS=(
  "$HOME/Library/Application Support/Google/Chrome"
  "$HOME/Library/Application Support/Google/Chrome Beta"
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
  "$HOME/Library/Application Support/Microsoft Edge"
  "$HOME/Library/Application Support/Chromium"
)

if [[ "${1:-}" == "--uninstall" ]]; then
  for dir in "${BROWSERS[@]}"; do rm -f "$dir/NativeMessagingHosts/$HOST_NAME.json"; done
  rm -f "$INSTALL_DIR/safely-host"
  echo "Shlok helper removed."
  exit 0
fi

echo "Building the helper…"
(cd "$ROOT/core" && swift build -c release --product safely-host)

mkdir -p "$INSTALL_DIR"
cp "$ROOT/core/.build/release/safely-host" "$INSTALL_DIR/safely-host"
chmod 755 "$INSTALL_DIR/safely-host"
codesign --force --sign - "$INSTALL_DIR/safely-host" 2>/dev/null || true

for dir in "${BROWSERS[@]}"; do
  [[ -d "$dir" ]] || continue
  mkdir -p "$dir/NativeMessagingHosts"
  cat > "$dir/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Shlok Bluetooth helper — relays encrypted messages to the Shlok Key",
  "path": "$INSTALL_DIR/safely-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
  echo "Registered with: ${dir##*/Application Support/}"
done

cat <<DONE

Done. Next:
  1. Chrome → chrome://extensions → enable Developer mode → "Load unpacked" → choose: $ROOT/extension
  2. If macOS asks whether Chrome may use Bluetooth, allow it.
  3. The Shlok setup page opens and walks you through pairing.
Helper log: ~/Library/Logs/Safely/host.log
DONE
