#!/bin/bash
# Install a released NotchDeck build and clear the quarantine flag so the unsigned app opens.
#
#   scripts/install.sh                     download the latest release and install it
#   scripts/install.sh v1.0.0              download that release tag
#   scripts/install.sh NotchDeck-1.0.0.dmg install from a DMG you already have
#   scripts/install.sh NotchDeck.app       install an app bundle you already have
#
# Downloads use the GitHub CLI (`gh`, signed in) when it is installed, which also works for a private
# fork; otherwise plain curl against the public GitHub API. Installs to /Applications, or to
# ~/Applications when /Applications is not writable (standard accounts).
# NOTCHDECK_INSTALL_DIR overrides the target folder; NOTCHDECK_NO_OPEN=1 skips launching.
set -euo pipefail

REPO="${NOTCHDECK_REPO:-salomohutapea/NotchDeck}"
ARG="${1:-}"

WORK="$(mktemp -d -t notchdeck-install)"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

die() { echo "error: $*" >&2; exit 1; }

download() {
  local tag="$1"
  echo "Downloading ${tag:-latest release} from $REPO..."
  if command -v gh >/dev/null 2>&1; then
    # `gh release download` without a tag takes the latest release.
    gh release download ${tag:+"$tag"} -R "$REPO" -p "NotchDeck-*.dmg" -D "$WORK" \
      || die "download failed (signed in to gh with access to $REPO? try: gh auth login)"
  else
    local api="https://api.github.com/repos/$REPO/releases/${tag:+tags/$tag}"
    [ -n "$tag" ] || api="${api}latest"
    local url
    url="$(curl -fsSL "$api" | grep -o '"browser_download_url": *"[^"]*NotchDeck-[^"]*\.dmg"' | head -1 | sed 's/.*"\(http[^"]*\)"/\1/')" \
      || die "could not read the release from GitHub (private repository? install gh and sign in)"
    [ -n "$url" ] || die "no DMG found in the release"
    curl -fL --progress-bar -o "$WORK/$(basename "$url")" "$url"
  fi
  DMG="$(ls "$WORK"/NotchDeck-*.dmg 2>/dev/null | head -1)"
  [ -n "$DMG" ] || die "no DMG downloaded"
}

DMG=""
SRC_APP=""
case "$ARG" in
  "")              download "" ;;
  *.dmg)           [ -f "$ARG" ] || die "not found: $ARG"; DMG="$ARG" ;;
  *.app|*.app/)    [ -d "$ARG" ] || die "not found: $ARG"; SRC_APP="${ARG%/}" ;;
  v*)              download "$ARG" ;;
  *)               die "unknown argument: $ARG (expected a vX.Y.Z tag, a .dmg or a .app)" ;;
esac

if [ -n "$DMG" ]; then
  # Verify against the published checksum when it sits next to the DMG.
  if [ -f "$DMG.sha256" ]; then
    (cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) || die "checksum mismatch for $DMG"
  fi
  MOUNT="$WORK/mnt"
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" || die "could not open $DMG"
  SRC_APP="$MOUNT/NotchDeck.app"
  [ -d "$SRC_APP" ] || die "NotchDeck.app not found in $DMG"
fi

DEST_DIR="${NOTCHDECK_INSTALL_DIR:-/Applications}"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "/Applications is not writable for this account; installing to $DEST_DIR"
fi
DEST="$DEST_DIR/NotchDeck.app"

# Quit the copy being replaced (not one running from somewhere else).
for pid in $(pgrep -x NotchDeck || true); do
  case "$(ps -o comm= -p "$pid")" in
    "$DEST"/*) echo "Quitting the running NotchDeck..."; kill "$pid" 2>/dev/null || true; sleep 1 ;;
  esac
done

rm -rf "$DEST"
ditto "$SRC_APP" "$DEST"
# Unsigned build: drop the "downloaded from the internet" flag so Gatekeeper does not block it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "Installed NotchDeck $VERSION to $DEST"
[ "${NOTCHDECK_NO_OPEN:-0}" = "1" ] || open "$DEST"
