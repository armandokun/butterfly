#!/bin/zsh
# Builds Butterfly.app into ./build and signs it with a stable identity
# (so macOS keeps Mic/Accessibility permissions between rebuilds).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
# Command Line Tools ship the macOS 27 SDK without the SwiftUI macro plugin (only full Xcode has it):
# build against the newest macOS 26 SDK instead. Same app, still runs on macOS 27.
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == "$CLT" && ! -e $CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ]]; then
  SDK=$(ls -d $CLT/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$SDK" ]] && export SDKROOT=$SDK
fi
swift build -c "$CONFIG"

APP=build/Butterfly.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/CTRL" "$APP/Contents/MacOS/Butterfly"
# Info.plist is shared with the Xcode project: fill in Xcode's $(VARIABLES) for CLI builds.
sed -e 's/$(EXECUTABLE_NAME)/Butterfly/g' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.armandas.ctrl/g' \
    -e 's/$(PRODUCT_NAME)/Butterfly/g' -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' -e 's/$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g' \
    -e 's/$(MARKETING_VERSION)/0.1.0/g' -e 's/$(CURRENT_PROJECT_VERSION)/1/g' -e 's/$(MACOSX_DEPLOYMENT_TARGET)/26.0/g' \
    Resources/Info.plist > "$APP/Contents/Info.plist"
# Now Playing for any app (mediaremote-adapter, BSD-3: github.com/ungive/mediaremote-adapter)
mkdir -p "$APP/Contents/Resources"
cp -R Resources/MediaRemoteAdapter "$APP/Contents/Resources/"
cp Resources/Art/*.png "$APP/Contents/Resources/"
# App icon: Icon Composer document (Liquid Glass; light/dark/tinted/clear) → Assets.car + .icns fallback.
if xcrun --find actool >/dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
  xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null
else
  ICONSET=$(mktemp -d)/CTRL.iconset; mkdir -p "$ICONSET"
  cp Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true

IDENTITY=${CTRL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
