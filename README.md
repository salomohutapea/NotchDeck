# NotchDeck

A macOS menu-bar app that turns the MacBook notch into a Dynamic-Island-style surface for developers.
Hover the notch to open it; live activities and short peek banners appear without getting in the way.

Requires macOS 14+, Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). No third-party packages.

## Modules

| Module | What it does |
|---|---|
| **Home** | One wide layout: Music & Lyrics, Devtools and AI Agents side by side |
| **Now Playing** | Artwork, scrubbable progress and transport controls for Music and Spotify |
| **Music & Lyrics** | Time-synced lyrics from [LRCLIB](https://lrclib.net), cached locally |
| **AI Agents** | Live status of Claude Code and Codex sessions (thinking, running a tool, needs input, done) via hooks |
| **Devtools** | React Native dev server status and bundle progress, reload / dev menu / DevTools target picker, configurable command buttons with live output inside the notch |
| **Builds** | Xcode, Gradle and command-line (`ndrun`) build progress and results |
| **Shelf** | Drop files on the notch, drag them back out, AirDrop or share |
| **Clipboard** | History with search, pinning, and previews for JSON, JWT, base64, colors and links; skips password managers |
| **System** | Peek banners for battery and charging, volume, brightness, Wi-Fi / VPN / offline and Bluetooth devices; icons in the collapsed notch for downloads, microphone / camera in use and screen recording |
| **Focus** | Pomodoro timer with a countdown in the collapsed notch |

Swipe gestures (flick up to close, scroll sideways to switch tabs), a floating capsule on displays without a notch, a display picker and size / animation settings are in Settings → General.

Event peeks (a track change, a finished build, an agent needing input) show as a slim banner by default.
Change this in Settings → General.

## Install

One line in Terminal installs the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/salomohutapea/NotchDeck/main/scripts/install.sh | bash
```

Builds are **unsigned** (no Apple Developer account), so macOS would block them as coming from an unidentified
developer. The script downloads the DMG, checks it against its published `.sha256`, quits a running copy, installs to
`/Applications` (or `~/Applications` on a standard account), removes the `com.apple.quarantine` flag and launches the app.

A specific version, or a DMG you already downloaded (from a clone of this repo):

```sh
curl -fsSL https://raw.githubusercontent.com/salomohutapea/NotchDeck/main/scripts/install.sh | bash -s -- v1.1.0
scripts/install.sh ~/Downloads/NotchDeck-1.1.0.dmg
```

To do it by hand: download `NotchDeck-<version>.dmg` from [Releases](https://github.com/salomohutapea/NotchDeck/releases),
drag NotchDeck to Applications, then either click Open Anyway in System Settings > Privacy & Security or run:

```sh
xattr -dr com.apple.quarantine /Applications/NotchDeck.app
```

## Build and run

```sh
xcodegen generate
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Debug \
  -derivedDataPath build/dd build CODE_SIGN_IDENTITY=-
open build/dd/Build/Products/Debug/NotchDeck.app
```

The Xcode project is generated from `project.yml` and is not committed.

`scripts/install-local.sh` builds Release and installs it to `/Applications`. It signs with a self-signed
"NotchDeck Local" code-signing certificate from your keychain when present (set `NOTCHDECK_SIGN_IDENTITY` to use
another), so privacy approvals such as Accessibility survive reinstalls; otherwise it signs ad-hoc.

`scripts/make-dmg.sh` builds a universal Release app and packs `dist/NotchDeck-<version>.dmg`. Pushing a `v*` tag runs
`.github/workflows/release.yml`, which does the same on GitHub Actions and publishes the release.

## Setup

- **AI Agents:** Settings → AI Agents → Install adds hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`
  (backed up first, uninstallable). Events go to a local server on `127.0.0.1:47474`.
- **Builds:** Settings → Builds installs the `ndrun` wrapper (`ndrun ./gradlew assembleDebug`) and an optional Gradle init hook.
- **Music:** macOS asks once for permission to control Music / Spotify.
- **Clipboard hotkey:** ⌃⌘V. Everything stays on your machine.

## Devtools commands

The default Devtools commands are generic starters (React Native dev server, `adb reverse`, Android Studio).
Edit, add or reorder them in Settings → Devtools; they run through `zsh -ilc`, so your PATH and nvm apply.

## Layout

- `NotchDeck/Core` module contracts, settings, coordinator, shared UI
- `NotchDeck/Notch` panel, shape, geometry, root view
- `NotchDeck/Modules/*` one folder per module
- `docs/ARCHITECTURE.md` contracts and per-module design notes

## Status

Built with Claude Code. Most visual behavior (animations, hover, drag and drop, hotkeys) was developed without
screenshots and has had limited hands-on testing, so expect rough edges.

## License and trademarks

MIT, see [LICENSE](LICENSE). The Claude, OpenAI, Android and Apple marks (from [Simple Icons](https://simpleicons.org), CC0)
are trademarks of their respective owners, used only to identify those products inside the app.
