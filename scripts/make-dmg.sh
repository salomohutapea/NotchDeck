#!/bin/sh
# Builds a Release NotchDeck.app and packs it into dist/NotchDeck-<version>.dmg.
#
#   scripts/make-dmg.sh            # ad-hoc signed, i.e. unsigned for Gatekeeper (what releases use)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/make-dmg.sh   # Developer ID signed
#   NOTARY_PROFILE=my-profile SIGN_IDENTITY=... scripts/make-dmg.sh              # + notarize and staple
set -eu
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q

DERIVED="build/release"
mkdir -p build
rm -rf "$DERIVED" dist/stage
if ! xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" build > build/release-build.log 2>&1; then
  echo "Release build failed:" >&2
  grep -E "error:|warning: .*(swift-driver|SDK)" build/release-build.log | sort -u | head -40 >&2
  tail -25 build/release-build.log >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release/NotchDeck.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
IDENTITY="${SIGN_IDENTITY:--}"

echo "Signing as: $IDENTITY"
codesign --force --deep --options runtime --timestamp="$([ "$IDENTITY" = "-" ] && echo none || echo http://timestamp.apple.com/ts01)" \
  --entitlements NotchDeck/Resources/NotchDeck.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

[ -x "$APP/Contents/MacOS/NotchDeck" ] || { echo "Build produced no executable" >&2; exit 1; }
for f in ndrun.sh notchdeck-hook.sh AppIcon.icns; do
  [ -f "$APP/Contents/Resources/$f" ] || { echo "App bundle is missing $f" >&2; exit 1; }
done
mkdir -p dist/stage
cp -R "$APP" dist/stage/
ln -s /Applications dist/stage/Applications
DMG="dist/NotchDeck-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "NotchDeck $VERSION" -srcfolder dist/stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/stage

if [ "$IDENTITY" != "-" ]; then codesign --force --sign "$IDENTITY" --timestamp "$DMG"; fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

( cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
echo "Built $DMG"
