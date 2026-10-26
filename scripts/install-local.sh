#!/bin/bash
# Build a Release NotchDeck and install it to /Applications for local use.
#
# Signs with a stable local identity (default "NotchDeck Local", a self-signed code-signing
# certificate in your login keychain) so macOS privacy approvals such as Accessibility survive
# reinstalls; ad-hoc signatures change on every build and invalidate them.
# Falls back to ad-hoc signing when the identity is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${NOTCHDECK_SIGN_IDENTITY:-NotchDeck Local}"
DD=build/rel
LOG=build/install-local.log
mkdir -p build

xcodegen generate >/dev/null
if ! xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Release \
    -derivedDataPath "$DD" build CODE_SIGN_IDENTITY=- >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -20 >&2 || true
  echo "Build failed, see $LOG" >&2
  exit 1
fi

APP="$DD/Build/Products/Release/NotchDeck.app"
pkill -x NotchDeck 2>/dev/null && sleep 1 || true
rm -rf /Applications/NotchDeck.app
cp -R "$APP" /Applications/

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --options runtime --preserve-metadata=entitlements -s "$IDENTITY" /Applications/NotchDeck.app
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --deep -s - /Applications/NotchDeck.app
  echo "\"$IDENTITY\" not found, signed ad-hoc (privacy approvals reset on each install)"
fi
xattr -dr com.apple.quarantine /Applications/NotchDeck.app 2>/dev/null || true
open /Applications/NotchDeck.app
