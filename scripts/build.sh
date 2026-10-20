#!/bin/zsh
# Builds CTRL.app into ./build and signs it with a stable identity
# (so macOS keeps Mic/Accessibility permissions between rebuilds).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG"

APP=build/CTRL.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/CTRL" "$APP/Contents/MacOS/CTRL"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Now Playing for any app (mediaremote-adapter, BSD-3: github.com/ungive/mediaremote-adapter)
mkdir -p "$APP/Contents/Resources"
cp -R Resources/MediaRemoteAdapter "$APP/Contents/Resources/"

IDENTITY=${CTRL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
