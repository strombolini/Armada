#!/bin/bash
# One-shot setup for Armada: build → install to /Applications → store the Codiv key → launch → verify.
#
#   CODIV_API_KEY=sk-codiv-... ./scripts/setup.sh
#   ./scripts/setup.sh --key sk-codiv-...
#   ./scripts/setup.sh --no-launch        # build + install only
#
# Requirements: macOS 15+, Xcode 16+ (full Xcode, not just Command Line Tools), Homebrew (for xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="${CODIV_API_KEY:-${TYPESAFE_API_KEY:-}}"
LAUNCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Checking toolchain"
if ! xcode-select -p >/dev/null 2>&1 || ! [ -d "$(xcode-select -p)/Platforms/MacOSX.platform" ]; then
  echo "Full Xcode is required (App Store → Xcode), then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; exit 1
fi
xcodebuild -version | head -1
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install xcodegen; else
    echo "xcodegen not found and Homebrew missing. Either install Homebrew (https://brew.sh) or use the checked-in Armada.xcodeproj."; fi
fi
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null; fi

# A real signing identity keeps the app's code identity stable across rebuilds, so macOS remembers the
# Full Disk Access / folder grants. Ad-hoc ("-") works too but every rebuild re-asks.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"(Apple Development|Developer ID Application|Mac Developer)[^"]*"' | head -1 | tr -d '"')
fi
[ -z "$IDENTITY" ] && IDENTITY="-"
step "Building (Release, signing identity: $IDENTITY)"
xcodebuild -project Armada.xcodeproj -scheme Armada -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGNING_ALLOWED=YES build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="build/Build/Products/Release/Armada.app"
[ -d "$APP" ] || { echo "build failed — run the xcodebuild line above without the grep to see why"; exit 1; }

step "Installing to /Applications"
pkill -x "Armada" 2>/dev/null || true; sleep 1
rm -rf "/Applications/Armada.app"
cp -R "$APP" "/Applications/Armada.app"
BIN="/Applications/Armada.app/Contents/MacOS/Armada"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Armada.app" 2>/dev/null || true

if [ -n "$KEY" ]; then
  step "Storing the Codiv API key"
  "$BIN" --set-key "$KEY"
  "$BIN" --ping
else
  echo "No key given (CODIV_API_KEY / --key). Get one at https://codiv.ai/signup, then: \"$BIN\" --set-key sk-codiv-..."
fi

if [ "$LAUNCH" = 1 ]; then
  step "Launching"
  open "/Applications/Armada.app"
  sleep 2
  pgrep -x "Armada" >/dev/null && echo "Armada is running (menu-bar icon: sparkle magnifying glass)."
  "$BIN" --doctor || true
fi

cat <<'EOF'

Next (one-time, by the human — the app shows a setup checklist window with a button for each):
  1. Full Disk Access → turn on Armada (click "+" and pick it if it isn't listed). Replaces the per-folder prompts.
  ⌘ Space needs nothing: Jev turns Spotlight's own shortcut off while it runs and restores it when it quits.

Verify headless:  "/Applications/Armada.app/Contents/MacOS/Armada" --search "the ikea receipt"
Open the panel:   open "armada://search?q=old%20resume"
EOF
