#!/bin/zsh
# Builds CTRL, installs it to /Applications, and launches it (it registers itself to open at login).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x CTRL 2>/dev/null && sleep 1 || true
rm -rf /Applications/CTRL.app
ditto build/CTRL.app /Applications/CTRL.app
open /Applications/CTRL.app
echo "Installed /Applications/CTRL.app"
