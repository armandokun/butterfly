#!/bin/zsh
# Release build: Xcode archive → Developer ID signed → notarized → stapled → Butterfly.zip + /Applications.
# One-time: xcrun notarytool store-credentials CTRL --apple-id <you@icloud.com> --team-id NLHT9F6F5X
#           (it asks for an app-specific password from account.apple.com)
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
OUT=build/release
rm -rf "$OUT"; mkdir -p "$OUT"

xcodebuild -project CTRL.xcodeproj -scheme CTRL -configuration Release \
  -archivePath "$OUT/CTRL.xcarchive" archive | xcbeautify 2>/dev/null || true
[[ -d "$OUT/CTRL.xcarchive" ]] || { echo "archive failed"; exit 1; }

cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>NLHT9F6F5X</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/CTRL.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT" -quiet
APP="$OUT/Butterfly.app"

# The bundled helper framework must carry our Developer ID too.
codesign --force --timestamp --options runtime --sign "Developer ID Application" "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --timestamp --options runtime --entitlements Resources/CTRL.entitlements --sign "Developer ID Application" "$APP"

ditto -c -k --keepParent "$APP" "$OUT/Butterfly.zip"
if xcrun notarytool history --keychain-profile CTRL >/dev/null 2>&1; then
  xcrun notarytool submit "$OUT/Butterfly.zip" --keychain-profile CTRL --wait
  xcrun stapler staple "$APP"
  rm "$OUT/Butterfly.zip"; ditto -c -k --keepParent "$APP" "$OUT/Butterfly.zip"
  echo "Notarized ✓"
else
  echo "Skipped notarization (run the store-credentials line at the top once)."
fi

pkill -x Butterfly 2>/dev/null && sleep 1 || true
rm -rf /Applications/Butterfly.app
ditto "$APP" /Applications/Butterfly.app
open /Applications/Butterfly.app
echo "Installed /Applications/Butterfly.app · shareable: $OUT/Butterfly.zip"
