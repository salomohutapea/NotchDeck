import SwiftUI
import AppKit
import Observation

// MARK: - Model

enum MediaSource: String, CaseIterable, Codable {
    case music, spotify

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var appName: String { self == .music ? "Music" : "Spotify" }
    var symbol: String { self == .music ? "music.note" : "dot.radiowaves.left.and.right" }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// UserDefaults key `media.preferredSource`: "auto" | "music" | "spotify".
enum MediaPreference {
    static let key = "media.preferredSource"
    static var current: MediaSource? {
        MediaSource(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
    }
}

struct Track: Equatable {
    /// Stable identity (source + persistent id / spotify uri).
    var key: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var source: MediaSource
    var artwork: NSImage?
}

// MARK: - AppleScript runner (one dedicated serial queue)

final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()
    private let queue = DispatchQueue(label: "app.notchdeck.media.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    func run(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.runSync(source)) }
        }
    }

    private func runSync(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            cache[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            #if DEBUG
            NSLog("NotchDeck AppleScript error: \(error)")
            #endif
            return nil
        }
        return result
    }
}

// MARK: - Scripts

private enum Scripts {
    static let music = """
    tell application "Music"
        set ps to player state as text
        if ps is "stopped" then return {"stopped"}
        set t to missing value
        try
            set t to current track
        end try
        if t is missing value then return {"stopped"}
        set n to ""
        set a to ""
        set al to ""
        set d to 0
        set p to 0
        set pid to ""
        try
            set n to name of t
        end try
        try
            set a to artist of t
        end try
        try
            set al to album of t
        end try
        try
            set d to ((duration of t) * 1000) as integer
        end try
        try
            set p to (player position * 1000) as integer
        end try
        try
            set pid to persistent ID of t
        end try
        return {ps, n, a, al, d, p, pid, ""}
    end tell
    """

    static let spotify = """
    tell application "Spotify"
        set ps to player state as text
        if ps is "stopped" then return {"stopped"}
        set t to missing value
        try
            set t to current track
        end try
        if t is missing value then return {"stopped"}
        set n to ""
        set a to ""
        set al to ""
        set d to 0
        set p to 0
        set tid to ""
        set art to ""
        try
            set n to name of t
        end try
        try
            set a to artist of t
        end try
        try
            set al to album of t
        end try
        try
            set d to duration of t
        end try
        try
            set p to (player position * 1000) as integer
        end try
        try
            set tid to id of t
        end try
        try
            set art to artwork url of t
        end try
        return {ps, n, a, al, d, p, tid, art}
    end tell
    """

    static let musicArtwork = """
    tell application "Music"
        try
            return data of artwork 1 of current track
        on error
            return missing value
        end try
    end tell
    """

    static func snapshot(_ s: MediaSource) -> String { s == .music ? music : spotify }
}

// MARK: - Service

@MainActor @Observable
final class MediaService {
    static let shared = MediaService()

    private(set) var track: Track?
    private(set) var isPlaying = false
    /// Position (seconds) at `positionUpdatedAt`. Views should use `currentPosition(at:)`.
    private(set) var position: TimeInterval = 0
    private(set) var positionUpdatedAt = Date()
    private(set) var artworkTint: Color = Color(red: 0.55, green: 0.65, blue: 1.0)

    @ObservationIgnored private let runner = AppleScriptRunner.shared
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var artworkCache: [String: (NSImage, Color)] = [:]
    @ObservationIgnored private var artworkOrder: [String] = []
    @ObservationIgnored private var artworkLoadingKey: String?

    private init() {}

    // MARK: Lifecycle (ref-counted: NowPlaying + MusicLyrics both use it)

    func acquire() {
        users += 1
        guard users == 1 else { return }
        installObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerTick() }
        }
        scheduleRefresh()
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        clear()
    }

    private func installObservers() {
        let dist = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            let t = dist.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            observers.append((dist, t))
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let t = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                guard id == MediaSource.music.bundleID || id == MediaSource.spotify.bundleID else { return }
                Task { @MainActor in self?.scheduleRefresh() }
            }
            observers.append((ws, t))
        }
    }

    private func timerTick() {
        tick += 1
        if isPlaying || tick % 5 == 0 { scheduleRefresh() }
    }

    // MARK: Position

    func currentPosition(at date: Date = Date()) -> TimeInterval {
        let base = isPlaying ? position + max(0, date.timeIntervalSince(positionUpdatedAt)) : position
        let dur = track?.duration ?? 0
        return dur > 0 ? min(max(0, base), dur) : max(0, base)
    }

    // MARK: Commands

    func playPause() {
        guard track != nil else { return }
        let now = Date()
        position = currentPosition(at: now)
        positionUpdatedAt = now
        isPlaying.toggle()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to time: TimeInterval) {
        guard let track else { return }
        let t = track.duration > 0 ? min(max(0, time), track.duration) : max(0, time)
        position = t
        positionUpdatedAt = Date()
        send("set player position to " + String(format: "%.2f", t))
    }

    private func send(_ command: String) {
        guard let source = track?.source, source.isRunning else { return }
        let script = "tell application \"\(source.appName)\" to \(command)"
        Task {
            _ = await runner.run(script)
            try? await Task.sleep(for: .milliseconds(250))
            scheduleRefresh()
        }
    }

    // MARK: Refresh

    func scheduleRefresh() {
        guard users > 0 else { return }
        if refreshing { needsRefresh = true; return }
        refreshing = true
        Task {
            repeat {
                needsRefresh = false
                await refreshOnce()
            } while needsRefresh && users > 0
            refreshing = false
        }
    }

    private struct Snapshot {
        var source: MediaSource
        var playing: Bool
        var title, artist, album, key: String
        var duration, position: TimeInterval
        var artworkURL: URL?
    }

    private func refreshOnce() async {
        let running = MediaSource.allCases.filter(\.isRunning)
        guard !running.isEmpty else { clear(); return }
        var snaps: [Snapshot] = []
        for source in running {
            if let desc = await runner.run(Scripts.snapshot(source)), let s = Self.parse(desc, source: source) {
                snaps.append(s)
            }
        }
        guard users > 0 else { return }
        apply(choose(snaps))
    }

    private func choose(_ snaps: [Snapshot]) -> Snapshot? {
        let playing = snaps.filter(\.playing)
        let candidates = playing.isEmpty ? snaps : playing
        if candidates.count > 1 {
            if let pref = MediaPreference.current, let s = candidates.first(where: { $0.source == pref }) { return s }
            if let cur = track?.source, let s = candidates.first(where: { $0.source == cur }) { return s }
        }
        return candidates.first
    }

    private static func parse(_ d: NSAppleEventDescriptor, source: MediaSource) -> Snapshot? {
        guard d.numberOfItems >= 7, let state = d.atIndex(1)?.stringValue, state != "stopped" else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { Double(str(i)) ?? 0 }
        let title = str(2)
        let id = str(7)
        let key = source.rawValue + ":" + (id.isEmpty ? title + "|" + str(3) : id)
        var url: URL?
        var art = str(8)
        if art.hasPrefix("http://") { art = "https://" + art.dropFirst(7) }
        if !art.isEmpty { url = URL(string: art) }
        return Snapshot(source: source, playing: state == "playing", title: title, artist: str(3), album: str(4), key: key,
                        duration: num(5) / 1000, position: num(6) / 1000, artworkURL: url)
    }

    private func clear() {
        if track != nil { track = nil }
        if isPlaying { isPlaying = false }
        position = 0
    }

    private func apply(_ snap: Snapshot?) {
        guard let snap else { clear(); return }
        if track?.key != snap.key {
            let cached = artworkCache[snap.key]
            track = Track(key: snap.key, title: snap.title, artist: snap.artist, album: snap.album,
                          duration: snap.duration, source: snap.source, artwork: cached?.0)
            if let cached { artworkTint = cached.1 } else { loadArtwork(for: snap) }
        } else if var t = track {
            t.duration = snap.duration
            t.title = snap.title
            t.artist = snap.artist
            t.album = snap.album
            if t != track { track = t }
        }
        if isPlaying != snap.playing { isPlaying = snap.playing }
        position = snap.position
        positionUpdatedAt = Date()
    }

    // MARK: Artwork

    private func loadArtwork(for snap: Snapshot) {
        artworkLoadingKey = snap.key
        let key = snap.key
        Task {
            var data: Data?
            switch snap.source {
            case .music:
                data = await runner.run(Scripts.musicArtwork)?.data
            case .spotify:
                if let url = snap.artworkURL {
                    data = try? await URLSession.shared.data(from: url).0
                }
            }
            guard let data, !data.isEmpty, let image = NSImage(data: data) else { return }
            let tint = Self.tint(of: image)
            store(image: image, tint: tint, key: key)
        }
    }

    private func store(image: NSImage, tint: Color, key: String) {
        artworkCache[key] = (image, tint)
        artworkOrder.removeAll { $0 == key }
        artworkOrder.append(key)
        if artworkOrder.count > 24, let old = artworkOrder.first {
            artworkOrder.removeFirst()
            artworkCache[old] = nil
        }
        guard track?.key == key else { return }
        track?.artwork = image
        artworkTint = tint
    }

    /// Average colour weighted towards vivid pixels, then boosted so it reads on black.
    static func tint(of image: NSImage) -> Color {
        let fallback = Color(red: 0.55, green: 0.65, blue: 1.0)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return fallback }
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in 0..<(n * n) {
            let pr = Double(pixels[i * 4]) / 255, pg = Double(pixels[i * 4 + 1]) / 255, pb = Double(pixels[i * 4 + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let w = 0.05 + sat * mx
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        guard wsum > 0 else { return fallback }
        let color = NSColor(deviceRed: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        if s > 0.12 { s = min(1, max(s * 1.15, 0.5)) }
        br = max(br, 0.82)
        return Color(nsColor: NSColor(hue: h, saturation: s, brightness: br, alpha: 1))
    }
}
