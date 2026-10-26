import Foundation
import Observation

enum LyricsState {
    case idle
    case loading
    case synced([LRCLine])
    case plain(String)
    case instrumental
    case notFound
    /// LRCLIB could not be reached; retried automatically.
    case unavailable
}

struct LyricsPayload: Codable {
    var synced: String?
    var plain: String?
    var instrumental: Bool
}

private struct LRCLibRecord: Decodable {
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?

    var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var payload: LyricsPayload {
        LyricsPayload(synced: hasSynced ? syncedLyrics : nil, plain: hasPlain ? plainLyrics : nil, instrumental: instrumental ?? false)
    }
}

/// LRCLIB client + disk cache. All members are nonisolated and safe to call from any context.
enum LRCLib {
    static let userAgent = "NotchDeck/1.0 (https://github.com/)"
    private static let base = "https://lrclib.net/api"

    struct Failure: Error {}

    static func cacheKey(for t: Track) -> String { "\(t.artist)-\(t.title)-\(Int(t.duration.rounded()))" }

    /// nil = definitively no lyrics. Throws when LRCLIB could not be reached (so callers do not cache).
    static func fetch(title: String, artist: String, album: String, duration: TimeInterval) async throws -> LyricsPayload? {
        let want = Want(title: title, artist: artist, duration: duration)
        var pool: [LRCLibRecord] = []
        var reached = false, failed = false

        func consider(_ recs: [LRCLibRecord]) -> LyricsPayload? {
            pool.append(contentsOf: recs)
            // Stop early on a confident synced match.
            if let best = pickBest(pool, want), best.hasSynced, score(best, want) >= 5 { return best.payload }
            return nil
        }

        let cleanTitle = cleaned(title), cleanArtist = primaryArtist(artist)
        var steps: [(String, [URLQueryItem])] = []
        // 1. Exact signature (needs album + duration).
        if !album.isEmpty, duration > 0 {
            steps.append(("get", [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                                  .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))]))
        }
        // 2. Structured search, as given and cleaned up ("Song (Remastered 2011)" -> "Song", first artist only).
        steps.append(("search", [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]))
        if cleanTitle != title || cleanArtist != artist {
            steps.append(("search", [.init(name: "track_name", value: cleanTitle), .init(name: "artist_name", value: cleanArtist)]))
        }
        // 3. Free-text search as a last resort.
        steps.append(("search", [.init(name: "q", value: "\(cleanArtist) \(cleanTitle)")]))

        for (path, items) in steps {
            do {
                guard let data = try await request(path, items) else { reached = true; continue }
                reached = true
                let dec = JSONDecoder()
                let recs: [LRCLibRecord]
                if path == "get" { recs = (try? dec.decode(LRCLibRecord.self, from: data)).map { [$0] } ?? [] }
                else { recs = (try? dec.decode([LRCLibRecord].self, from: data)) ?? [] }
                if let done = consider(recs) { return done }
            } catch {
                failed = true
            }
        }
        if let best = pickBest(pool, want) { return best.payload }
        if failed && !reached { throw Failure() }
        return nil
    }

    private struct Want {
        let title: String
        let artist: String
        let duration: TimeInterval
    }

    /// Lowercased, accents and punctuation removed, bracketed parts dropped.
    static func normalized(_ s: String) -> String {
        var t = s
        for (o, c) in [("(", ")"), ("[", "]")] {
            while let r = t.range(of: o), let e = t.range(of: c, range: r.upperBound..<t.endIndex) {
                t.removeSubrange(r.lowerBound..<e.upperBound)
            }
        }
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        let kept = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Variant words that mean a different recording unless the playing title has them too.
    private static let variantWords = ["live", "remix", "acoustic", "instrumental", "karaoke", "cover", "sped up",
                                       "slowed", "music video", "official video", "lyric video", "demo", "version"]

    /// 0 = reject. Title must match; artist and duration add confidence.
    private static func score(_ r: LRCLibRecord, _ w: Want) -> Int {
        let rt = normalized(r.trackName ?? ""), wt = normalized(w.title)
        let wtClean = normalized(cleaned(w.title))
        guard !rt.isEmpty, !wt.isEmpty else { return 0 }
        var s: Int
        if rt == wt || rt == wtClean { s = 3 }
        else if rt.contains(wtClean) || wtClean.contains(rt) { s = 1 }
        else { return 0 }

        let ra = normalized(r.artistName ?? ""), wa = normalized(primaryArtist(w.artist))
        if !wa.isEmpty, !ra.isEmpty {
            if ra.contains(wa) || wa.contains(ra) { s += 2 } else { s -= 2 }
        }
        if w.duration > 0, let d = r.duration {
            let diff = abs(d - w.duration)
            if diff > 4 { return 0 }
            if diff <= 1.5 { s += 1 }
        }
        let rawTitle = (r.trackName ?? "").lowercased(), playing = w.title.lowercased()
        for v in variantWords where rawTitle.contains(v) && !playing.contains(v) { s -= 2 }
        return max(0, s)
    }

    /// Best record: confident matches only; synced before plain before instrumental, then score, then duration.
    private static func pickBest(_ recs: [LRCLibRecord], _ w: Want) -> LRCLibRecord? {
        let scored = recs.map { ($0, score($0, w)) }.filter { $0.1 >= 2 }
        func dist(_ r: LRCLibRecord) -> Double { w.duration > 0 ? abs((r.duration ?? w.duration) - w.duration) : 0 }
        func kind(_ r: LRCLibRecord) -> Int { r.hasSynced ? 2 : (r.hasPlain ? 1 : (r.instrumental == true ? 0 : -1)) }
        return scored.filter { kind($0.0) >= 0 }.max { a, b in
            if kind(a.0) != kind(b.0) { return kind(a.0) < kind(b.0) }
            if a.1 != b.1 { return a.1 < b.1 }
            return dist(a.0) > dist(b.0)
        }?.0
    }

    /// One retry on "busy" / rate-limit answers. nil on 404.
    private static func request(_ path: String, _ items: [URLQueryItem]) async throws -> Data? {
        guard var comps = URLComponents(string: "\(base)/\(path)") else { throw Failure() }
        comps.queryItems = items
        guard let url = comps.url else { throw Failure() }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Failure() }
            if http.statusCode == 404 { return nil }
            if (200..<300).contains(http.statusCode) { return sanitized(data) }
            guard http.statusCode == 429 || http.statusCode >= 500, attempt < 2 else { throw Failure() }
            try await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
        }
        throw Failure()
    }

    /// LRCLIB sometimes returns raw control characters inside strings, which JSONDecoder rejects.
    static func sanitized(_ data: Data) -> Data {
        guard data.contains(where: { $0 < 0x20 }) else { return data }
        var out = Data(capacity: data.count + 64)
        for b in data {
            switch b {
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])   // \n
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])   // \r
            case 0x09: out.append(contentsOf: [0x5C, 0x74])   // \t
            case ..<0x20: continue
            default: out.append(b)
            }
        }
        return out
    }

    // MARK: title cleanup

    static func cleaned(_ title: String) -> String {
        var t = title
        for open in ["(", "["] {
            if let r = t.range(of: open) { t = String(t[..<r.lowerBound]) }
        }
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        for marker in [" feat.", " feat ", " ft.", " featuring "] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    static func primaryArtist(_ artist: String) -> String {
        var a = artist
        for sep in [" & ", ",", " feat", " ft.", " x ", " with "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        let trimmed = a.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }

    // MARK: disk cache

    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NotchDeck/lyrics", isDirectory: true)
    }()

    private static func file(for key: String) -> URL {
        let safe = String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.prefix(140))
        var h: UInt64 = 14695981039346656037
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheDir.appendingPathComponent("\(safe)-\(String(h, radix: 16)).json")
    }

    static func readCache(_ key: String) -> LyricsPayload? {
        guard let data = try? Data(contentsOf: file(for: key)) else { return nil }
        return try? JSONDecoder().decode(LyricsPayload.self, from: data)
    }

    static func removeCache(_ key: String) { try? FileManager.default.removeItem(at: file(for: key)) }

    static func writeCache(_ key: String, _ payload: LyricsPayload) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) { try? data.write(to: file(for: key), options: .atomic) }
    }
}

@MainActor @Observable
final class LyricsStore {
    private(set) var state: LyricsState = .idle
    private(set) var key: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memory: [String: LyricsPayload] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var track: Track?

    func load(for track: Track?) {
        guard let track else {
            task?.cancel(); key = nil; self.track = nil; state = .idle; return
        }
        let cacheKey = LRCLib.cacheKey(for: track)
        guard cacheKey != key else { return }
        key = cacheKey
        self.track = track
        task?.cancel()

        if let p = memory[cacheKey] { state = Self.state(from: p); return }
        if missing.contains(cacheKey) { state = .notFound; return }
        state = .loading
        fetch(track, key: cacheKey, useDisk: true)
    }

    /// Forget what is cached for the current track and look it up again ("wrong lyrics").
    func searchAgain() {
        guard let track, let key else { return }
        memory[key] = nil
        missing.remove(key)
        task?.cancel()
        state = .loading
        Task.detached { LRCLib.removeCache(key) }
        fetch(track, key: key, useDisk: false)
    }

    private func fetch(_ track: Track, key cacheKey: String, useDisk: Bool, attempt: Int = 0) {
        let (title, artist, album, duration) = (track.title, track.artist, track.album, track.duration)
        task = Task { [weak self] in
            if useDisk, let disk = await Task.detached(operation: { LRCLib.readCache(cacheKey) }).value {
                guard !Task.isCancelled, let self, self.key == cacheKey else { return }
                self.memory[cacheKey] = disk
                self.state = Self.state(from: disk)
                return
            }
            do {
                let payload = try await LRCLib.fetch(title: title, artist: artist, album: album, duration: duration)
                guard !Task.isCancelled, let self, self.key == cacheKey else { return }
                if let payload {
                    self.memory[cacheKey] = payload
                    self.state = Self.state(from: payload)
                    Task.detached { LRCLib.writeCache(cacheKey, payload) }
                } else {
                    self.missing.insert(cacheKey)
                    self.state = .notFound
                }
            } catch {
                guard !Task.isCancelled, let self, self.key == cacheKey else { return }
                // LRCLIB busy or offline: not cached; try again a few times while the track plays.
                self.state = .unavailable
                guard attempt < 4 else { return }
                try? await Task.sleep(for: .seconds(15 * Double(attempt + 1)))
                guard !Task.isCancelled, self.key == cacheKey else { return }
                self.fetch(track, key: cacheKey, useDisk: false, attempt: attempt + 1)
            }
        }
    }

    private static func state(from p: LyricsPayload) -> LyricsState {
        if let s = p.synced {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = p.plain, !plain.isEmpty { return .plain(plain) }
        return p.instrumental ? .instrumental : .notFound
    }
}
