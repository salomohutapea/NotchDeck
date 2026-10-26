import Foundation
import Darwin

/// Watches `~/Library/Application Support/NotchDeck/builds/` for start/finish JSON records
/// written by `ndrun` and the Gradle hook. Callbacks are delivered on the main queue.
final class BuildSpool: @unchecked Sendable {
    static let directory: URL = {
        if let o = ProcessInfo.processInfo.environment["NOTCHDECK_SPOOL"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchDeck/builds", isDirectory: true)
    }()

    var onRecords: ([SpoolRecord]) -> Void = { _ in }
    /// Keys of CLI builds whose wrapper process vanished without writing a finish record.
    var onOrphans: ([SpoolRecord]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "notchdeck.build.spool", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var fileStamps: [String: Date] = [:]
    private var openStarts: [String: SpoolRecord] = [:]
    private var finished = Set<String>()

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            attachDirectoryWatch()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.1, repeating: 2.0, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.scan() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            source?.cancel(); source = nil
            fileStamps = [:]; openStarts = [:]; finished = []
        }
    }

    private func attachDirectoryWatch() {
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    private func scan() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var batch: [SpoolRecord] = []
        let now = Date()
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(mtime) > 86_400 {
                try? fm.removeItem(at: url)
                continue
            }
            if fileStamps[url.lastPathComponent] == mtime { continue }
            fileStamps[url.lastPathComponent] = mtime
            guard let data = try? Data(contentsOf: url),
                  let rec = try? decoder.decode(SpoolRecord.self, from: data) else {
                fileStamps[url.lastPathComponent] = nil   // maybe half-written; retry next scan
                continue
            }
            if rec.kind == "start" { if !finished.contains(rec.key) { openStarts[rec.key] = rec } }
            else if rec.kind == "progress" { /* live task counts; does not end the build */ }
            else { openStarts[rec.key] = nil; finished.insert(rec.key) }
            batch.append(rec)
        }
        if !batch.isEmpty { DispatchQueue.main.async { [onRecords] in onRecords(batch) } }

        // Wrapper killed (SIGKILL / terminal closed) -> no finish record will ever arrive.
        var orphans: [SpoolRecord] = []
        for (key, rec) in openStarts where rec.source == "cli" {
            guard let pid = rec.pid, kill(pid, 0) != 0, errno == ESRCH else { continue }
            orphans.append(rec)
            openStarts[key] = nil
            finished.insert(key)
        }
        if !orphans.isEmpty { DispatchQueue.main.async { [onOrphans] in onOrphans(orphans) } }
    }
}
