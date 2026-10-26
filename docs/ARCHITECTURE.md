# NotchDeck — Architecture & Contracts

A macOS menu-bar agent app (LSUIElement) that turns the MacBook notch into a
Dynamic-Island-style surface with user-selectable modules.

Target: macOS 14.0+, Swift 6 language mode **off** (use Swift 5 mode, `SWIFT_VERSION = 5.0`)
to avoid strict-concurrency churn. SwiftUI + AppKit. Observation framework (`@Observable`).
Not sandboxed (needs AppleScript, localhost networking, writing hook configs).
Project generated with XcodeGen (`project.yml`); sources are globbed, so new files
inside `NotchDeck/` are picked up after `xcodegen generate`.

Build command (each agent uses its OWN derived-data path):

```
cd ~/Developer/NotchDeck && xcodegen generate && \
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -configuration Debug \
  -derivedDataPath <your-scratch-dir>/dd build CODE_SIGN_IDENTITY=- 2>&1 | grep -E "error|warning: unre|BUILD" | head -50
```

## Folder layout and ownership

```
project.yml                       core
NotchDeck/App/                    core   (NotchDeckApp, AppDelegate, menu bar item)
NotchDeck/Core/                   core   (contracts below — DO NOT change signatures without orchestrator)
NotchDeck/Notch/                  core   (panel, shape, geometry, root view, hover logic)
NotchDeck/Settings/               core   (settings window)
NotchDeck/Resources/              core   (Info.plist, Assets, entitlements) + AI agent adds notchdeck-hook.sh
NotchDeck/Modules/Media/          media agent  (shared MediaService: Music.app + Spotify)
NotchDeck/Modules/NowPlaying/     media agent
NotchDeck/Modules/MusicLyrics/    media agent
NotchDeck/Modules/AIStatus/       ai agent
NotchDeck/Modules/Metro/          metro agent
```

A feature agent edits ONLY its own folders. If the build fails because of
errors in someone else's folder, ignore them (another agent is mid-edit),
re-run later, and report it.

## Core contracts (NotchDeck/Core)

```swift
enum ModuleID: String, CaseIterable, Codable, Identifiable {
    case nowPlaying, musicLyrics, aiStatus, metro
    var id: String { rawValue }
    var title: String        // "Now Playing", "Music & Lyrics", "AI Agents", "Metro"
    var systemImage: String  // "play.circle.fill", "quote.bubble.fill", "sparkles", "atom"
}

@MainActor
protocol NotchModule: AnyObject {
    var id: ModuleID { get }
    /// Has something live right now (drives the collapsed "live activity" pill).
    var isLive: Bool { get }
    /// Higher wins the collapsed leading slot. Guide: AI thinking 100, Metro bundling 90,
    /// music playing 50, lyrics 40, idle 0.
    var compactPriority: Int { get }
    /// Collapsed views. Height = notch height (~32pt). Max width each side = NotchMetrics.compactSideWidth (≈ 76pt).
    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    /// Expanded content. Fits in NotchMetrics.expandedContentSize (≈ 500 x 170 pt). Dark background, white text.
    func expanded() -> AnyView
    /// Optional per-module section in the Settings window (Form section content).
    func settings() -> AnyView?
    func start()
    func stop()
}
```

Module classes are `@MainActor @Observable final class` types whose live state is
stored properties, so SwiftUI/Observation tracks `isLive`/`compactPriority` through
the existential automatically.

Concrete module class names (core creates stubs; feature agents replace them, keeping
a no-argument `init()`):

| ModuleID     | Class               | File                                        |
|--------------|---------------------|---------------------------------------------|
| nowPlaying   | `NowPlayingModule`  | Modules/NowPlaying/NowPlayingModule.swift   |
| musicLyrics  | `MusicLyricsModule` | Modules/MusicLyrics/MusicLyricsModule.swift |
| aiStatus     | `AIStatusModule`    | Modules/AIStatus/AIStatusModule.swift       |
| metro        | `MetroModule`       | Modules/Metro/MetroModule.swift             |

`ModuleRegistry.shared` (Core) owns one instance of each, exposes
`module(for: ModuleID) -> any NotchModule`, and starts/stops modules when the user
enables/disables them.

`AppSettings.shared` (Core, `@Observable`, UserDefaults-backed):
- `enabledModules: [ModuleID]` — ordered; order = tab order. Default: all four.
- `expandOnHover: Bool` (true), `hoverDelay: Double` (0.15s), `collapseDelay` (0.35s)
- `showLiveActivities: Bool` (true) — widen collapsed notch with compact views
- `peekStyle: PeekStyle` (`.compact` default | `.full` | `.off`; key `peekStyle`, migrated from legacy `peekOnEvents == false` -> `.off`).
  `peekOnEvents: Bool` is now computed (`peekStyle != .off`).
- `launchAtLogin: Bool` (SMAppService.mainApp)
- `showMenuBarIcon: Bool` (true)
Modules keep their own settings in their own `@AppStorage`/UserDefaults keys
prefixed with the module rawValue (e.g. `metro.ports`).

`NotchCoordinator.shared` (Core, `@Observable`):
- `state: NotchState` — `.collapsed`, `.peeking(ModuleID)`, `.expanded`
- `selectedModule: ModuleID?`
- `func peek(_ id: ModuleID, duration: TimeInterval = 4)` — modules call this on
  notable events (Claude finished, bundle done/failed, track changed). Ignored if
  `peekStyle` is `.off` or the module is disabled, and never while `.expanded`. `.full`: the notch opens to the
  expanded size showing that module. `.compact` (default): a slim banner (`NotchLayout.peek`, width = notch +
  2x`peekSideWidth` (100), height = notch + 34pt, bottom radius 16, subtle shadow; the top notch-height strip stays
  empty) showing the module's `peekContent()` in one ~26pt row (banner width - 28pt). Duration is capped at 3s for
  nowPlaying and 5s otherwise. A new peek while one shows just swaps content (crossfade keyed on `peekToken`) and restarts
  the timer. Hovering a peek converts it to `.expanded`; its hit rect is its own size.
- `NotchModule.peekContent() -> AnyView?` (default nil via protocol extension). If nil, the compact peek falls back to
  the live-activity layout with that module's `compactLeading/Trailing` forced into both slots.

`NotchMetrics` (Core): `compactSideWidth = 76`, `expandedContentSize = CGSize(500,170)`,
`cornerRadius` values, and helpers to read real notch size from the screen.

Shared UI helpers in Core/UI: `NotchTheme` (colors, fonts), `MarqueeText` (auto-
scrolling single-line text), `PulsingDot`.

## Notch shell behaviour (core)

- One borderless non-activating `NSPanel` per notched screen (fallback: main screen,
  drawn as a pill under the menu bar). Level `.statusBar` + 1 or higher, collection
  behaviour `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`,
  transparent background, no shadow when collapsed.
- The panel is sized to the max expanded frame and stays put; the SwiftUI root animates
  a `NotchShape` (black, top corners flare outward like the hardware notch, bottom
  corners rounded) between sizes. `ignoresMouseEvents` is true except while the mouse
  is inside the current shape's rect (global + local mouse-moved monitors).
- Collapsed: exactly the hardware notch when nothing is live. When live and
  `showLiveActivities`: width grows by `compactSideWidth` on each side; leading = top
  live module's `compactLeading`, trailing = the second live module's `compactTrailing`
  if any, else the top module's `compactTrailing`.
- Expanded (hover): top row = tab icons for enabled modules (selected highlighted) +
  gear button (opens Settings); below = selected module's `expanded()`. Default tab =
  top live module, else first enabled. Spring animation (`.spring(response: 0.38, dampingFraction: 0.8)`).
- Menu bar extra (`MenuBarExtra` or NSStatusItem): Settings…, toggle modules, Quit.
- Settings window: General (toggles above), Modules (list with enable toggle +
  drag-to-reorder), then each module's `settings()` section.

## Module specs

### Media (Modules/Media) — shared by NowPlaying + MusicLyrics
`MediaService.shared` (`@MainActor @Observable`):
- Sources: Music.app and Spotify via `NSAppleScript` on a dedicated serial queue.
  NEVER send AppleScript to an app unless `NSRunningApplication` shows it running
  (AppleScript would launch it). Listen to distributed notifications
  `com.apple.Music.playerInfo` and `com.spotify.client.PlaybackStateChanged` for instant
  updates; poll position every 1s while playing (interpolate locally between polls).
- State: `track: Track?` (title, artist, album, duration, artwork NSImage, source app,
  persistentID/stable key), `isPlaying`, `position`, `positionUpdatedAt`,
  `artworkTint: Color` (average/dominant colour of artwork).
- Commands: playPause, next, previous, seek(to:), toggleShuffle/repeat if cheap.
- Artwork: Music → `raw data of artwork 1 of current track` (descriptor `.data`);
  Spotify → `artwork url of current track` fetched with URLSession. Cache by track key.
- Info.plist already has `NSAppleEventsUsageDescription`; entitlements allow apple events.

NowPlayingModule: compact leading = 22pt rounded artwork; trailing = animated
equalizer bars tinted `artworkTint` (static when paused). Expanded = 96pt artwork,
title/artist (MarqueeText), scrubbable progress bar with elapsed/remaining, prev /
play-pause / next. isLive = track != nil && isPlaying. Peek briefly on track change.

MusicLyricsModule: synced lyrics from LRCLIB (`https://lrclib.net/api/get?artist_name=&track_name=&album_name=&duration=`,
fall back to `/api/search?q=`), parse LRC `[mm:ss.xx]`, cache per track (memory +
disk in Application Support). Expanded = small art + controls on the left, lyrics on
the right auto-scrolling with the current line highlighted and neighbours dimmed;
plain lyrics (non-synced) shown statically; "No lyrics" state. Compact trailing =
current lyric line is too wide, so compact views = artwork + small quote icon;
isLive = false (NowPlaying owns the collapsed slot) unless NowPlaying is disabled.
Set User-Agent `NotchDeck/1.0 (https://github.com/)`.

### AI agents (Modules/AIStatus)
- `HookServer`: `NWListener` on 127.0.0.1 port 47474 (setting `aiStatus.port`), minimal
  HTTP/1.1: `POST /hook?agent=claude|codex` with the raw hook JSON body; reply 200
  immediately. Also `GET /health`.
- `Resources/notchdeck-hook.sh`: reads stdin, forwards with
  `curl -s -m 1 -X POST --data-binary @- "http://127.0.0.1:${NOTCHDECK_PORT:-47474}/hook?agent=$1"`
  in the background, prints NOTHING to stdout (Claude adds UserPromptSubmit stdout to
  context), always `exit 0`.
- Installer (buttons in module settings): copies the script to
  `~/Library/Application Support/NotchDeck/notchdeck-hook.sh` (chmod +x) and merges
  hook entries into `~/.claude/settings.json` (Claude Code; create if missing) and
  `~/.codex/hooks.json` (Codex; same JSON schema as Claude:
  `{"hooks":{"Event":[{"hooks":[{"type":"command","command":"…"}]}]}}`). Make a
  timestamped backup first, preserve all existing keys/hooks, be idempotent (detect our
  command string), and offer Uninstall. Claude events: SessionStart, UserPromptSubmit,
  PreToolUse, PostToolUse, Notification, Stop, SubagentStop, SessionEnd. Codex events:
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop.
- Session model keyed by `session_id`: agent, cwd → project name, last prompt
  (truncated), state `.thinking`, `.tool(name)`, `.waitingForUser(message)` (Notification),
  `.done(at)`, `.idle`; startedAt for elapsed timer. Stop → `.done` and peek; done →
  idle after 10s; stale thinking > 15 min → idle; SessionEnd removes.
- Compact leading: agent glyph (Claude = orange `sparkle`, Codex = white/teal
  `chevron.left.forwardslash.chevron.right`) with pulse while working; trailing: short
  status ("Bash", "Thinking", elapsed "1:23", or ✓). Expanded: list of active sessions
  (agent icon, project, status, elapsed, prompt snippet); empty state with "Install
  hooks" hint when nothing has ever been received.
- isLive = any session thinking/tool/waiting, or done within 10s. Priority 100
  (waitingForUser 110).

### Metro (Modules/Metro)
- Ports from setting `metro.ports` (default `[8081]`).
- Poll `GET http://localhost:<port>/status` every 3s → "packager-status:running"
  means up.
- When up, connect `URLSessionWebSocketTask` to `ws://localhost:<port>/events`
  (reporter events, JSON text frames, possibly `{"type":"...", ...}` directly or wrapped
  — parse defensively and log unknown shapes in DEBUG). Handle `bundle_build_started`
  (bundleDetails.platform, entryFile), `bundle_transform_progressed`
  (transformedFileCount/totalFileCount), `bundle_build_done`, `bundle_build_failed`,
  `client_log` (ignore), `initialize_done`. Reconnect with backoff.
- Fallback if `/events` is unavailable: status only (Running/Offline).
- Actions: Reload (connect `ws://localhost:<port>/message` and send
  `{"version":2,"method":"reload"}`), Open DevTools (`POST /open-debugger`), Open dev
  menu (`{"version":2,"method":"devMenu"}`).
- Compact leading: cyan `atom` icon (spinning while bundling); trailing: percentage
  or progress ring; ✓/✗ for 5s after done/failed. Expanded: card per port: status,
  platform, progress bar, file counts, last build duration, error message, buttons.
- isLive while bundling or 5s after done/failed. Priority 90. Peek on failed (and on
  done if the build took > 3s).

## Conventions
- No third-party packages. Foundation, AppKit, SwiftUI, Network, ServiceManagement only.
- All UI state on the main actor; network/AppleScript off-main.
- Dark UI: background is the black notch; use white/secondary text, SF Symbols.
- Keep files small and focused; no force-unwraps on external data.

## Metro protocol notes (verified against RN 0.84 / Metro 0.83, @react-native-community/cli-server-api)

- `GET /status` -> `packager-status:running`.
- `ws://localhost:<port>/events` EXISTS. Each Metro reporter event is sent as a bare JSON text
  frame (no envelope): `{"type":"bundle_build_started","buildID":"…","bundleDetails":{"entryFile":"/abs/index.ios.js","platform":"ios","dev":true,…},"isPrefetch":false}`,
  `bundle_transform_progressed` (`transformedFileCount`, `totalFileCount`), `bundle_build_done` (`{buildID,type}` only
  — NO duration, measured locally), `bundle_build_failed` (`{buildID,type}` only — message arrives in a separate
  `bundling_error` event whose `error` is a pretty-format string, ANSI-coloured), plus `client_log`, `initialize_done`, etc.
  `buildID` is a short random id; concurrent builds (ios+android) are tracked per id. Cached/warm rebuilds emit
  started -> done with no progress events at all.
- **Reload / Dev menu**: `ws://localhost:<port>/events` accepts `{"version":2,"type":"command","command":"reload"|"devMenu"}`
  (cli-server-api `createEventsSocketEndpoint`: a `command` message becomes server-side `messageSocket.broadcast(command, params)`,
  the very call the terminal "r"/"d" keys make). `MetroService` sends it on its existing events socket (or a fresh one) and falls
  back to `/message` with `{"version":2,"method":"reload"|"devMenu"}` if the send fails.
- **DevTools**: `POST /json/list` returns targets `[{id,title,description,deviceName,appId,...}]` (several per device are normal);
  `POST /open-debugger?target=<urlencoded id>` opens one (mirrors `OpenDebuggerKeyboardHandler`; it labels duplicates with
  `description`). `MetroService.targets` is refreshed with every 3s status poll; the UI opens directly for 1 target, shows a Menu
  of `deviceName - title (description) #n` labels for several. Never POST `/open-debugger` without `target` (opens the first).
- Source-map `MAP` lines in the dev server log are DevTools fetching sources, unrelated to reload.
- Origin check on `/events`: only no-Origin or `http://localhost:*` — URLSession sends none, so fine.
- Implementation: progress is monotonic (`max` of ratio, capped 0.98 until done) and eased at ~30 Hz; results
  (done/failed) show in the collapsed pill for 5s. Peek on failure, or success if build > 3s (setting `metro.peekOnFinish`).

## Wave 2 modules

| ModuleID     | Class                | Folder              | Owner        |
|--------------|----------------------|---------------------|--------------|
| buildStatus  | `BuildStatusModule`  | Modules/BuildStatus | build agent  |
| fileShelf    | `FileShelfModule`    | Modules/FileShelf   | shelf agent  |
| clipboard    | `ClipboardModule`    | Modules/Clipboard   | clipboard agent |
| pomodoro     | `PomodoroModule`     | Modules/Pomodoro    | focus agent  |

Core additions: `NotchCoordinator.shared.open(_ id:)` opens the notch on the primary
display with that module selected (toggles closed if already showing). New module IDs
are auto-enabled once for existing users via the `knownModules` defaults key.
Each wave-2 agent documents its design in a short section below.

## Wave 2 core changes

- **Tab header**: tabs are split across both sides of the hardware notch (left half
  left-aligned, remainder on the right, then the gear). `TabPlan.make` (NotchRootView.swift)
  computes capacity from the real per-side width: 30pt tabs, then 24pt, then overflow tabs
  collapse into an ellipsis `Menu` next to the gear (highlighted when the selected tab is inside).
- **Drag to notch**: global `leftMouseDragged` monitor compares `NSPasteboard(name: .drag).changeCount`
  with the value at mouse-down and checks the pointer is inside `NotchScreenContext.dragRect()`
  (wider/taller than the notch). Then `NotchCoordinator.dragEntered` expands (never toggles) and
  selects `.fileShelf` (if enabled). `NotchCoordinator.isDragActive` (observable) is true until mouse
  up; auto-collapse is suppressed meanwhile and resumes ~0.25s after mouse up. The panel stops
  ignoring mouse events while a drag is inside the drag rect so SwiftUI `.onDrop` receives the drop.
- **Dismissal**: global mouse-down outside the expanded rect collapses; Escape (local key monitor,
  while the panel is key) collapses. `NotchPanel.canBecomeKey` is true only while the notch is
  open; `open(_:)` additionally makes the panel key (non-activating) so text fields can type.
- **Hotkeys**: `HotkeyCenter.shared.register(id:keyCode:modifiers:handler:) -> Bool` and
  `unregister(id:)` (Carbon `RegisterEventHotKey`, no Accessibility permission). Handler runs on
  the main actor. Re-registering an id replaces it. Call from a module's `start()`, and
  `unregister` in `stop()`. Key codes are Carbon `kVK_*` (e.g. `kVK_ANSI_V`), modifiers e.g.
  `[.command, .shift]`.
- Panel size (556 x ~246 + margin) already fits 500x170 content plus header; unchanged. The menu
  bar module toggle list is a flat list and works for 8 modules.

## FileShelf (Modules/FileShelf)

- `ShelfStore.shared` (`@MainActor @Observable`): `[ShelfItem]` (path + bookmark + `owned`), max 50, newest first.
  Index persisted at `~/Library/Application Support/NotchDeck/shelf.json` (unless `fileShelf.keepBetweenLaunches` is off,
  in which case index + generated files are wiped at launch). Moved files are re-resolved via the bookmark; vanished ones are dropped.
- Drops (`.onDrop` on the expanded view): file URLs are referenced in place; images are written as png, text as txt, web URLs as
  `.webloc` into `~/Library/Application Support/NotchDeck/Shelf/` (those are `owned` and deleted on Remove/Clear).
- Drag out: per-tile `.onDrag { NSItemProvider(contentsOf:) }`; "Drag all/N" handle is an AppKit `NSDraggingSource` that drags
  every selected item (or all). `fileShelf.removeAfterDrag` (default on): handle uses the drag operation result; single-tile drags
  (no completion callback in SwiftUI) poll for mouse-up and remove if the pointer ended outside NotchDeck windows. Owned files
  are not deleted in that case (receiver may still be copying).
- Cmd-click multi-select, double-click Quick Look (`QLPreviewPanel` driven directly by `QuickLookController`), context menu:
  Quick Look, Open, Reveal, Copy, AirDrop, Share submenu, Remove. Header: AirDrop all (selected or all), Clear.
- `isLive = false`, priority 10. TODO: the core's `NotchCoordinator.isDragActive` is not used; the drop highlight comes from `onDrop(isTargeted:)`.

### Focus (Modules/Pomodoro)
- Defaults 25 / 5 / 15 min (focus / short / long break), long break every 4 focus sessions. ⌃⌥P hotkey off by default.
- `PomodoroEngine` (PomodoroEngine.swift, Foundation-only, `Codable`) is a pure struct; every action and `tick(now:)` take
  `now`. Running state stores an absolute `endsAt`, so sleep/wake and relaunch are exact; the module ticks every 0.5s
  while running (plus on `NSWorkspace.didWakeNotification`) and persists the whole engine as JSON in `pomodoro.engine`.
- Phases focus/short/long; long break after N completed focus sessions (`completedInCycle`, reset after the long break).
  Skipping gives no credit. Phase end returns `.phaseEnded` -> module peeks (6s), plays NSSound, posts a notification.
  Defaults: auto-start breaks on, focus off. Presets (15/25/50) change the focus length and start immediately.
- Stats: per-day sessions/minutes (day key rolls at local midnight), streak = consecutive days with >=1 session.
- Other keys: `pomodoro.label|sound|mute|notify|hotkey`. Optional global hotkey ⌃⌥P (keyCode 35) via `HotkeyCenter`, default off.
- isLive while running/paused; compactPriority 60 running / 30 paused.

## Clipboard (Modules/Clipboard)

- `ClipboardMonitor` polls `NSPasteboard.general.changeCount` every 0.5s on the main run loop. Skips
  `org.nspasteboard.{Concealed,Transient,AutoGenerated}Type`, `com.agilebits.onepassword*`, and copies made while an
  excluded app (setting `clipboard.excludedApps`, bundle IDs; default 1Password, Bitwarden, Keychain Access, Passwords)
  is frontmost. Order of capture: file URLs, image (only if no string), string, NSColor.
- `ClipboardStore` (`@Observable`): dedupes by content (moves to top), cap `clipboard.maxItems` (200) evicting only
  unpinned. Persistence (`clipboard.remember`, default on): `~/Library/Application Support/NotchDeck/clipboard.json`
  plus images as PNG (downscaled to <= 1 MB) in sibling `clipboard-images/`. Remember off or "Clear history" wipes both.
  Copy-back sets `ownChangeCount` so the monitor does not re-capture our own write. Nothing leaves the machine.
- `ClipDetect` (pure Foundation): JSON, JWT (decode only, exp as relative time), URL / deep link, hex colour (`#RGB/RRGGBB/RRGGBBAA`),
  base64 (only if it decodes to printable UTF-8), UUID, path, stack trace, code heuristic.
- UI: search + filter chips (All/Pinned/Text/Images/Links/Code), rows with badge, preview, source icon, age; hover shows
  pin/delete and Copy pretty / payload / decoded. Hovered (else last clicked) row drives the right-hand detail pane.
  Click copies back and flashes "Copied". Search typing needs the panel to be key (works after hotkey open).
- Hotkey Ctrl+Cmd+V (Cmd+Shift+V is Paste and Match Style) (`clipboard.hotkey`) -> `NotchCoordinator.shared.open(.clipboard)` via `HotkeyCenter` id `clipboard.open`.
- `isLive` false, `compactPriority` 5.

## BuildStatus (Modules/BuildStatus)

- **Xcode IDE** (`XcodeWatcher`): every 1.5s on a utility queue, scans the process table via libproc
  (`proc_listallpids` + `PROC_PIDTBSDINFO`; only while Xcode is running) for build tools (swift-frontend, clang, ld,
  ibtool, actool, …) whose ancestor is `SWBBuildService`/`XCBBuildService` *and* that service's parent is `Xcode`
  (so `xcodebuild` is excluded). Two consecutive hits = "building"; project name comes from the `DerivedData/<Name>-<hash>`
  path in the tool's argv (KERN_PROCARGS2). Finish/result comes from polling the mtime of
  `~/Library/Developer/Xcode/DerivedData/*/Logs/Build/LogStoreManifest.plist`. Verified keys per entry in `logs`:
  `uniqueIdentifier`, `title` ("Build <Scheme>"), `signature`, `domainType`, `fileName` (`<uuid>.xcactivitylog`, gzip),
  `timeStartedRecording`/`timeStoppedRecording` (seconds since 2001 reference date),
  `primaryObservable.{highLevelStatus (S/W/E…), totalNumberOfErrors, totalNumberOfWarnings, totalNumberOfAnalyzerIssues}`.
  Entries present at launch seed the per-project average only; new ones become results. On failure the first `error:` line
  is extracted from the gunzipped activity log. If tools vanish and no manifest entry arrives within 12s the live row is
  dropped (cancelled). Manifest entries overlapping an `ndrun xcodebuild` build are ignored (already tracked).
- **Spool** (`BuildSpool`): `~/Library/Application Support/NotchDeck/builds/` (env `NOTCHDECK_SPOOL` overrides in both app and
  scripts). Files `<id>.start.json` / `<id>.done.json`, written atomically (dot-temp + rename). Fields: `v,id,startId,kind
  (start|done),source (cli|gradle),project,title,cwd,pid,startedAt,endedAt (epoch s),exit,tail,message,errors,warnings`.
  A done record resolves the running build with `startId`; if that start is already finished (Gradle config-cache hit) it
  becomes a standalone result without duration. Watched with a DispatchSource on the dir + 2s poll; files > 24h old are
  deleted; CLI starts whose pid died without a done record are shown as "Interrupted".
- **ndrun** (`Resources/build/ndrun.sh`, installed to `…/NotchDeck/bin/ndrun`): in a TTY runs the command under `script -q`
  (pty, colours kept); otherwise stdout/stderr go through fifos + `tee` (streams stay separate). Exit code preserved, tail
  (20 lines, ANSI stripped) recorded on failure.
- **Gradle** (`GradleHookScripts.swift`, `BuildInstallers`): `~/.gradle/init.d/notchdeck.gradle` is a dispatcher wrapped in
  try/catch; Gradle >= 8.1 applies `~/.gradle/notchdeck/notchdeck-flow.gradle` (Settings plugin + Flow API `FlowScope.always`
  with `FlowProviders.buildWorkResult`, config-cache safe), older versions use `gradle.buildFinished`. Root build only,
  builds with no requested tasks (IDE sync) ignored. Install backs up a foreign file of the same name; uninstall removes both.
  Written from docs, not run against a real Gradle (none installed).
- **State**: `BuildRecord` list (max 30, 5 shown), per-key history of last 8 successful durations in UserDefaults
  (`buildStatus.history`; avg of last 5 drives the progress bar). isLive while running + 6s after a result; priority 95/85.
  Peek on failure or duration > `buildStatus.peekThreshold` (5s); notification (UNUserNotificationCenter, lazy auth) for
  builds > 30s (`buildStatus.notify`). Settings keys: `buildStatus.xcodeDetection|peekThreshold|notify|clearedAt|history`.

## Home dashboard, per-module size, hidden tabs

- **`NotchModule.preferredExpandedSize`** (default `NotchMetrics.expandedContentSize`, 500x170): content area the module wants.
  The expanded shape = content + header (notch height) + side padding (28/side) + bottom padding (20) and springs to the
  selected module's size on tab switch (`NotchScreenContext.expandedContent`, driven by `NotchCoordinator.shownModuleID`).
  The NSPanel is sized once for `ModuleRegistry.maxPreferredSize` + `panelMargin`, centred on the notch; `hitRect`/`dragRect`/
  `size(for:)` follow the current size so click-through outside the visible shape keeps working. The tab row is laid out
  against the current content width.
- **`NotchModule.dashboardSection() -> AnyView?`** (default nil): a pane for Home, drawn into a fixed frame.
- **Home (`.dashboard`, `DashboardModule`)**: 800 x 210 content (shrinks if panes are switched off). Three rounded cards
  (corner 14, white 5%) with 12pt gaps: Music & Lyrics 310 (`.musicLyrics`), Devtools 270 (`.metro`), AI Agents 196
  (`.aiStatus`), each 210 tall and clipped. A disabled/nil module shows a quiet placeholder. Per-pane toggles live in
  Home's settings (`AppSettings.dashboardShowMusic|Devtools|AI`). Home is never live, priority 0, no `peekContent`; peeks
  never show it (`peek(.dashboard)` is ignored; compact peeks always use the peeking module's own banner).
- **`AppSettings.hiddenTabs: Set<ModuleID>`** (key `hiddenTabs`): enabled modules without their own tab. The tab row =
  `NotchCoordinator.tabIDs` = enabled minus hidden (+ the selected module as a temporary tab if hidden). Hidden modules
  still run (live activities, peeks). One-time migration (`dashboardMigrated`; also the new-user default): hiddenTabs =
  nowPlaying, musicLyrics, metro, aiStatus and `.dashboard` moved to the front of `enabledModules`.
  Settings -> Modules has a "Show as tab" checkbox per module.
- **Selection**: expanding by hover selects the tab the user last chose within 60s, else Home (if shown as a tab), else the
  top live module / first tab. `NotchCoordinator.open(_:)` and `.full` peeks go through `resolveTab(_:)`: own tab if it has
  one, Home if Home hosts it (nowPlaying counts as the music pane), else the module itself as a temporary tab.

## Devtools (Modules/Metro, ModuleID `.metro`, title "Devtools")

- **CommandRunner** (`CommandRunner.swift`, `PTYProcess.swift`): `/bin/zsh -ilc <command>` via `posix_spawn` with an `openpty` slave as
  stdin/out/err, `POSIX_SPAWN_SETSID` (own session + process group), cwd per command, `TERM=xterm-256color`, 120x40 window, echo off.
  Login+interactive zsh is needed for nvm/aliases (custom CLIs). Output: raw bytes to `~/Library/Application Support/NotchDeck/logs/<id>.log`
  (colours kept, overwritten per run), ANSI-stripped lines (`\r` rewrites the line) into a 2000-line ring + a throttled 3-line `tail`.
  State: `idle / running(pid,startedAt) / succeeded(duration) / failed(exitCode,message,duration)`; message = last error-ish line.
  Stop = Ctrl-C byte + SIGINT to group and descendants (`proc_listchildpids`), SIGTERM after 3s, SIGKILL after 3 more. A user stop of a
  dev server counts as success; stops never peek.
- **Lifecycle safety**: pidfile `~/Library/Application Support/NotchDeck/run/<id>.pid` (`pid, startedAt, owner, command`). On `start()` the module
  reaps stale entries (owner NotchDeck dead, pid alive, kernel start time within 5s of the record). `NSApplication.willTerminateNotification`
  and `stop()` call `terminateAll()` (SIGTERM, 250ms, SIGKILL; interrupted tracked builds get a done record with exit 143).
- **Commands** (`DevCommand.swift`): JSON in UserDefaults `metro.commands` (id, name, SF symbol, command, cwd, kind `devServer|task|launcher`,
  `trackAsBuild`, `openInTerminal`). Defaults: Dev server, adb 8081, Android Studio (generic starters; the user's own list lives in preferences).
  Settings: add/edit/remove/reorder/restore defaults.
  `openInTerminal` runs `tell application "Terminal" to do script "cd <dir> && <cmd>"` + activate (no state tracking).
- **Track as build**: `BuildSpoolWriter` writes `<id>.start.json` at spawn (pid = shell pid) and `<id>.done.json` on exit into the BuildSpool
  directory (`NOTCHDECK_SPOOL` honoured), `id = "<epoch>-<pid>"`, `source:"cli"`, `project` = cwd basename, `title` = command name,
  `tail` = last 20 lines on failure. Same shape as `ndrun`.
- **Dev server section**: Metro detection per port is unchanged (status poll + `/events` progress). "Owned" = the `.devServer` command is running
  under our runner. Owned: Reload/Menu write `r`/`d` to the pty; external (e.g. started in Terminal): events-socket command. Start is disabled
  when the port answers but we do not own it ("Running outside NotchDeck"). Logs button runs `tail -f <log>` in Terminal; the card shows the last 2 lines.
- **Views**: `expanded()` = dev server card + adaptive task grid (running spinner + elapsed, hover shows Stop; failed shows last error on hover,
  click opens the log; context menu Run/Stop/Open log/Run in Terminal). `dashboardSection()` = fixed 270x200 compact version.
  Collapsed: bundling (90) as before; a running `.task` shows its symbol + elapsed (priority 70), result glyph for 6s; peek shows
  "iOS project 1:42" / "Sync strings failed <error>" (failed or > 3s, setting `metro.peekOnFinish`).

## Shell: gestures, display, appearance settings

Settings (all in `AppSettings`, Settings → General): `gesturesEnabled` (default on),
`animationStyle` (`.smooth` / `.snappy` / `.jelly`, default jelly), `displayMode`
(`.notchedOnly` default, `.mainScreen`, `.allScreens`, `.specific(id:name:)`),
`notchExtraWidth` (-30...60), `notchExtraHeight` (0...12), `hideInFullscreen` (default on).

- **Gestures** (`Notch/NotchGestureHandler.swift`): local + global `.scrollWheel` monitors in
  `NotchWindowManager`, active only while the pointer is inside a visible notch's `hitRect()`.
  Finger travel is normalised for natural scrolling (`isDirectionInvertedFromDevice`) and
  accumulated per gesture (reset on `phase.began`, or after a 0.3s pause for classic wheels;
  momentum events are ignored but swallowed after a recognised gesture). Axis locks after 8pt.
  Expanded: sideways >= 60pt switches tab (once per gesture, clamped, no wrap); upward >= 40pt
  collapses. Collapsed / live / peek: downward >= 40pt expands. Rule that keeps module scrolling
  intact: an upward swipe collapses only if the pointer is in the header strip (notch height + 8pt,
  the tab row) or the view under the pointer is not inside a vertically scrollable `NSScrollView`;
  a sideways swipe over a horizontally scrollable scroll view is left to it.
- **Animation style**: `NotchTheme.spring` follows `AnimationStyle.current` (read from
  UserDefaults). In jelly mode `NotchRootView` fires a `keyframeAnimator` after each shape size
  change: a <= 0.5s anisotropic scale (width overshoots while height lags, and vice versa; peak
  +-4%, anchored at the top) that stays inside the panel's transparent margin.
- **Floating capsule**: displays without a notch (`NotchMetrics.hasNotch` false) draw an all-corners
  rounded capsule (`NotchShape(floating: true)`), 190x32 base, `floatingTopGap` (6pt) below the top
  edge. `NotchScreenContext.topOffset` shifts the shape inside the panel; hit and drag rects
  include it. Notched displays are unchanged.
- **Notch size**: `NotchScreenContext.notchSize` = hardware size + extra width/height (notched
  displays only, read live from settings). `centerGap` (never below the hardware width) is the
  clear space for live/peek/expanded strips, so those layouts follow the collapsed shape. The panel
  reserves `maxExtraHeight + floatingTopGap` of extra height, so no rebuild is needed.
- **Displays**: `NotchWindowManager.targetScreens()` resolves `displayMode`; `.specific` matches by
  display ID then by `localizedName` and falls back to `.notchedOnly`. Panels rebuild when the mode
  or screen parameters change; the first target is `primaryDisplayID` (peeks go there).
- **Fullscreen hiding**: on `activeSpaceDidChange`, app activation and screen changes (re-checked
  at +0.45s / +1.35s) a display counts as fullscreen when `visibleFrame.maxY >= frame.maxY` (menu
  bar hidden) and the frontmost app has a window covering the display. The panel is then
  `orderOut`'d (and an open notch collapsed); it returns afterwards. With the setting off the
  panel stays above fullscreen apps.
