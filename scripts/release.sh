#!/bin/zsh
# Publishes a Butterfly release that every install picks up (Sparkle checks the feed daily).
#   ./scripts/release.sh 0.2.0
# Builds → Developer ID + hardened runtime → notarized + stapled (if set up) → Butterfly.zip
# → GitHub release on armandokun/butterfly-releases (public) with Butterfly.zip + appcast.xml.
# One-time setup (optional; without it, first open needs Open Anyway):
#   xcrun notarytool store-credentials CTRL --apple-id <you@icloud.com> --team-id NLHT9F6F5X
#   Sparkle signing key lives in the login keychain ("butterfly"); back it up:
#     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account butterfly -x butterfly-sparkle.key
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: release.sh <version, e.g. 0.2.0>}
REPO=armandokun/butterfly-releases
SPARKLE=.build/artifacts/sparkle/Sparkle/bin
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
NOTARIZE=0; xcrun notarytool history --keychain-profile CTRL >/dev/null 2>&1 && NOTARIZE=1

# Version: MARKETING_VERSION = what people see, CURRENT_PROJECT_VERSION = build number Sparkle compares.
BUILD=$(( $(awk '/CURRENT_PROJECT_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" -e "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate --quiet

./scripts/build.sh release
APP=build/Butterfly.app
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$APP/Contents/Info.plist"

# Distribution signing, inside out: Sparkle's helpers, then the frameworks, then the app.
SIGN=(codesign --force --timestamp --options runtime --sign "Developer ID Application")
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
$SIGN "$SP/XPCServices/Installer.xpc"
$SIGN --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
$SIGN "$SP/Autoupdate" "$SP/Updater.app"
$SIGN "$APP/Contents/Frameworks/Sparkle.framework"
$SIGN "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
$SIGN --entitlements Resources/CTRL.entitlements "$APP"
codesign --verify --deep --strict "$APP"

OUT=build/release; rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Butterfly.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
# Notarized: opens with no warning. Not: first open needs System Settings → Privacy & Security → Open Anyway.
if (( NOTARIZE )); then
  xcrun notarytool submit "$ZIP" --keychain-profile CTRL --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "Not notarized (no notarytool profile): first open needs Open Anyway."
fi

# Feed: one item, the latest release. Sparkle verifies the EdDSA signature against SUPublicEDKey.
SIG=$($SPARKLE/sign_update --account butterfly "$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/Butterfly.zip"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Butterfly</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF

# Notes: commit subjects since the last release.
LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
git log --format='- %s' ${LAST:+$LAST..}HEAD > "$OUT/notes.md"

git commit -qam "Release $VERSION" && git tag "v$VERSION" && git push -q && git push -q origin "v$VERSION"
gh release create "v$VERSION" -R "$REPO" --title "Butterfly $VERSION" --notes-file "$OUT/notes.md" "$ZIP" "$OUT/appcast.xml"

pkill -x Butterfly 2>/dev/null && sleep 1 || true
rm -rf /Applications/Butterfly.app
ditto "$APP" /Applications/Butterfly.app
open /Applications/Butterfly.app
echo "Released $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/v$VERSION"
