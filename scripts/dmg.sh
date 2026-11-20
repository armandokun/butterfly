#!/bin/zsh
# Packs an app into a styled drag-to-Applications disk image.
#   ./scripts/dmg.sh build/Butterfly.app build/release/Butterfly.dmg
# Lays out the window through Finder, so the first run asks to let the terminal control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?usage: dmg.sh <app> <out.dmg>}
DMG=${2:?usage: dmg.sh <app> <out.dmg>}
VOL=Butterfly
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$VOL.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift "$WORK/bg.png" 1
swift scripts/dmg-background.swift "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# A same-named volume would make Finder style the wrong window.
[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -force -quiet
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" -quiet
hdiutil attach "$RW" -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOL" -quiet

# Window 640×400 content (+28 title bar); icon positions match dmg-background.swift.
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 840, 548}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$VOL.app" to {170, 190}
    set position of item "Applications" to {470, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach "/Volumes/$VOL" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
