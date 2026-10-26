#!/bin/zsh
# Builds Butterfly, installs it to /Applications, and launches it (it registers itself to open at login).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x Butterfly 2>/dev/null && sleep 1 || true
rm -rf /Applications/Butterfly.app
ditto build/Butterfly.app /Applications/Butterfly.app
open /Applications/Butterfly.app
echo "Installed /Applications/Butterfly.app"
