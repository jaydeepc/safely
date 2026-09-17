#!/bin/bash
# Archives the iOS app and either exports an .ipa or uploads it straight to TestFlight.
#
#   scripts/testflight.sh            → build/export/Safely.ipa  (drag into the Transporter app)
#   scripts/testflight.sh --upload   → uploads to App Store Connect with the account signed in to Xcode
#
# One-time setup before the first run:
#   1. Xcode → Settings → Accounts: sign in with the Apple ID of team 93LMZFSB23.
#   2. App Store Connect → Apps → "+" → New App: platform iOS, bundle ID com.codecrackjd.safely.
#      (Xcode registers the bundle IDs, the app group and the AutoFill capability by itself on the first archive.)
# To use another bundle ID, change PRODUCT_BUNDLE_IDENTIFIER and the group id in ios/Config/*.entitlements
# and ios/Shared/SecureStorage.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$ROOT/build/Safely.xcarchive"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DESTINATION="export"; [[ "${1:-}" == "--upload" ]] && DESTINATION="upload"

OPTIONS="$(mktemp -t safely-export).plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>93LMZFSB23</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "▸ Archiving build ${BUILD_NUMBER}…"
xcodebuild -project "$ROOT/ios/Safely.xcodeproj" -scheme Safely -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive | grep -E "error:|warning: .*provision|ARCHIVE|\*\* " || true
[[ -d "$ARCHIVE" ]] || { echo "Archive failed — open ios/Safely.xcodeproj in Xcode and check Signing & Capabilities."; exit 1; }

echo "▸ Running $DESTINATION step…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$ROOT/build/export" -allowProvisioningUpdates | grep -E "error:|EXPORT|Upload|\*\* " || true
rm -f "$OPTIONS"

if [[ "$DESTINATION" == "upload" ]]; then
  echo "Uploaded. It appears in App Store Connect → TestFlight after ~10 minutes of processing."
else
  echo "IPA: $ROOT/build/export/Safely.ipa — open the Transporter app and drop it in, or re-run with --upload."
fi
