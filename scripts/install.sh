#!/bin/bash
# Install a released NotchDeck build and clear the quarantine flag so the unsigned app opens.
#
#   scripts/install.sh                     download the latest release and install it
#   scripts/install.sh v1.0.0              download that release tag
#   scripts/install.sh NotchDeck-1.0.0.dmg install from a DMG you already have
#   scripts/install.sh NotchDeck.app       install an app bundle you already have
#
# Can also run straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/salomohutapea/NotchDeck/main/scripts/install.sh | bash
#   curl -fsSL .../scripts/install.sh | bash -s -- v1.1.0
# Downloads with curl from the public release URLs, falling back to a signed-in GitHub CLI (`gh`)
# for private forks. The DMG is checked against its published .sha256. Installs to /Applications, or to
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
  echo "Downloading NotchDeck ${tag:-(latest release)} from $REPO..."
  # Public repository: release web URLs (no API calls, so no anonymous rate limit).
  if [ -z "$tag" ]; then
    tag="$(curl -fsSI "https://github.com/$REPO/releases/latest" 2>/dev/null \
           | tr -d '\r' | sed -n 's|^[Ll]ocation: .*/releases/tag/\(v[^/]*\)$|\1|p' | tail -1 || true)"
  fi
  local ok=""
  if [ -n "$tag" ]; then
    local name="NotchDeck-${tag#v}.dmg" base="https://github.com/$REPO/releases/download/$tag"
    if curl -fsSL -o "$WORK/$name" "$base/$name" 2>/dev/null; then
      ok=1
      curl -fsSL -o "$WORK/$name.sha256" "$base/$name.sha256" 2>/dev/null || rm -f "$WORK/$name.sha256"
    fi
  fi
  if [ -n "$ok" ]; then
    :
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # Private fork: release URLs need sign-in, so use the signed-in GitHub CLI.
    gh release download ${tag:+"$tag"} -R "$REPO" -p "NotchDeck-*.dmg*" -D "$WORK" \
      || die "download failed (does your gh account have access to $REPO?)"
  else
    die "could not find a release of $REPO${tag:+ tagged $tag} (private repository? sign in with: gh auth login)"
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
