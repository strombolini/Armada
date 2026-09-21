#!/bin/bash
# Armada installer — works from the release package (prebuilt app, ~15 s, no Xcode needed) and falls back to
# building from source when Xcode is available. Safe to re-run.
#
#   ./install.sh                         # asks for the key if none is stored
#   CODIV_API_KEY=sk-codiv-... ./install.sh
#   ./install.sh --key sk-codiv-...      # same
#   ./install.sh --build                 # force a source build even if a prebuilt app is present
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="${CODIV_API_KEY:-${TYPESAFE_API_KEY:-}}"; FORCE_BUILD=0
while [ $# -gt 0 ]; do case "$1" in --key) KEY="$2"; shift 2;; --build) FORCE_BUILD=1; shift;; *) echo "unknown option $1"; exit 2;; esac; done
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
DEST="/Applications/Armada.app"; BIN="$DEST/Contents/MacOS/Armada"

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 1; }
MAJOR=$(sw_vers -productVersion | cut -d. -f1); [ "$MAJOR" -ge 15 ] || { echo "macOS 15 or newer required (found $(sw_vers -productVersion))"; exit 1; }

PREBUILT=""
for c in "$HERE/Armada.app" "$HERE/../Armada.app" "$HERE/dist/Armada.app"; do [ -d "$c" ] && PREBUILT="$c" && break; done
SRC=""; for c in "$HERE/source" "$HERE/.." "$HERE"; do [ -f "$c/project.yml" ] && SRC="$c" && break; done

if [ -n "$PREBUILT" ] && [ "$FORCE_BUILD" = 0 ]; then
  step "Installing prebuilt app"
  pkill -x "Armada" 2>/dev/null || true; sleep 1
  rm -rf "$DEST"; cp -R "$PREBUILT" "$DEST"
  # Downloaded zips carry the quarantine flag; the app is signed with a developer certificate but not notarized,
  # so Gatekeeper would refuse to open it without this.
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
elif [ -n "$SRC" ]; then
  step "No prebuilt app — building from source"
  exec "$SRC/scripts/setup.sh" ${KEY:+--key "$KEY"}
else
  echo "Neither a prebuilt 'Armada.app' nor the source tree was found next to this script."; exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

if [ -z "$KEY" ] && ! "$BIN" --doctor 2>/dev/null | grep -q "^OK   api key stored"; then
  if [ -t 0 ]; then
    echo; echo "Get a free Codiv key: https://codiv.ai/signup → Dashboard → Create key (100M tokens, no card)."
    read -r -p "Paste your sk-codiv-… key (or press Enter to add it later in the app): " KEY || true
  fi
fi
if [ -n "$KEY" ]; then step "Storing the Codiv key"; "$BIN" --set-key "$KEY"; fi

step "Launching"
open "$DEST"; sleep 3
step "Status"
"$BIN" --doctor || true
cat <<'EOT'

The app opened a setup checklist. Two clicks finish it:
  • Full Disk Access → "Open Full Disk Access…" → turn on Armada (click "+" and pick it if it isn't listed).
Then press ⌘ Space and describe a file. Re-run this script any time; it never re-asks for what is already set.
EOT
