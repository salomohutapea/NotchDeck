import Foundation
import Darwin

/// A Gradle daemon started working on a build (as seen in its log).
struct GradleDaemonBuild: Equatable {
    var buildID: String
    var dir: String
    var startedAt: Date
}

/// Detects Gradle builds from the daemon logs (`~/.gradle/daemon/<version>/daemon-<pid>.out.log`).
///
/// The init-script hook cannot report a build that hits the configuration cache (the script never runs),
/// which is the common case for Android Studio runs. The daemon, however, always logs
/// "Received command: Build{id=..., currentDir=...}" and "Marking the daemon as busy / idle".
final class GradleDaemonWatcher: @unchecked Sendable {
    var onStart: (GradleDaemonBuild) -> Void = { _ in }
    var onFinish: (GradleDaemonBuild) -> Void = { _ in }

    private let queue = DispatchQueue(label: "notchdeck.gradle.daemons", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var active: [Int32: GradleDaemonBuild] = [:]
    private static let tailBytes = 400_000

    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gradle/daemon")
    private static let command = try! NSRegularExpression(pattern: #"Build\{id=([^,}]+), currentDir=([^}]+)\}"#)

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: 2.0, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            active = [:]
        }
    }

    private func poll() {
        var seen = Set<Int32>()
        let fm = FileManager.default
        let versions = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for dir in versions {
            let logs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in logs where url.lastPathComponent.hasPrefix("daemon-") && url.pathExtension == "log" {
                let name = url.deletingPathExtension().deletingPathExtension().lastPathComponent   // daemon-<pid>
                guard let pid = Int32(name.dropFirst("daemon-".count)), kill(pid, 0) == 0 else { continue }
                seen.insert(pid)
                evaluate(url: url, pid: pid)
            }
        }
        for (pid, build) in active where !seen.contains(pid) {
            active[pid] = nil
            DispatchQueue.main.async { [onFinish] in onFinish(build) }
        }
    }

    private func evaluate(url: URL, pid: Int32) {
        guard let state = Self.readState(url: url) else { return }   // nil = undetermined, keep previous
        switch (state.busy, active[pid]) {
        case (true, nil):
            let b = GradleDaemonBuild(buildID: state.buildID ?? "\(pid)-\(Int(state.since.timeIntervalSince1970))",
                                      dir: state.dir ?? "", startedAt: state.since)
            active[pid] = b
            DispatchQueue.main.async { [onStart] in onStart(b) }
        case (false, let b?):
            active[pid] = nil
            DispatchQueue.main.async { [onFinish] in onFinish(b) }
        default:
            break
        }
    }

    private struct LogState { var busy: Bool; var since: Date; var buildID: String?; var dir: String? }

    private static func readState(url: URL) -> LogState? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        var busy: Bool?
        var since = Date()
        var buildID: String?
        var dir: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("Marking the daemon as busy") {
                busy = true
                since = stamp.date(from: String(line.prefix(28))) ?? since
            } else if line.contains("Marking the daemon as idle") {
                busy = false
            } else if line.contains("Received command: Build{") {
                let s = String(line)
                if let m = command.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) {
                    buildID = String(s[a]); dir = String(s[b])
                }
            }
        }
        guard let busy else { return nil }
        return LogState(busy: busy, since: since, buildID: buildID, dir: dir)
    }
}
