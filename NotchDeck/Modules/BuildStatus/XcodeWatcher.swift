import Foundation
import AppKit
import Darwin

/// One finished Xcode build, read from `LogStoreManifest.plist`.
struct XcodeLogEntry {
    var uuid: String
    var project: String
    var title: String
    var started: Date
    var ended: Date
    var status: String
    var errors: Int
    var warnings: Int
    var logURL: URL
    /// Entry existed before the watcher started (used only to seed duration history).
    var isBaseline: Bool
}

struct XcodeActivity: Equatable {
    var project: String?
}

/// Polls (off-main) the process table for Xcode build tools and the DerivedData build-log
/// manifests for finished builds. All callbacks are delivered on the main queue.
final class XcodeWatcher: @unchecked Sendable {
    var onActivity: (XcodeActivity?) -> Void = { _ in }
    var onEntries: ([XcodeLogEntry]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "notchdeck.build.xcode", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var seen = Set<String>()
    private var mtimes: [String: Date] = [:]
    private var baselineDone = false
    private var lastActivity: XcodeActivity?
    private var consecutiveActive = 0

    private let derivedData = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")

    static let toolNames: Set<String> = [
        "swift-frontend", "swift-driver", "swiftc", "swift-build-tool", "ld", "ld-prime", "libtool", "lipo",
        "ibtool", "actool", "momc", "mapc", "intentbuilderc", "appintentsmetadataprocessor", "codesign",
        "dsymutil", "copypng", "ibtoold", "clang", "clang-cache", "builtin-copy", "swift-stdlib-tool",
        "sh", "bash", "zsh", "xcstringstool", "metal", "metallib"
    ]
    static let serviceNames: Set<String> = ["SWBBuildService", "XCBBuildService"]

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: 1.5, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            seen = []; mtimes = [:]; baselineDone = false
            lastActivity = nil; consecutiveActive = 0
        }
    }

    private func tick() {
        scanProcesses()
        scanManifests()
    }

    // MARK: Process table

    private struct Proc { var pid: Int32; var ppid: Int32; var name: String }

    private func scanProcesses() {
        var activity: XcodeActivity?
        let xcodeRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty == false
        if xcodeRunning {
            let procs = Self.listProcesses()
            let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            var project: String?
            var found = false
            for p in procs where Self.toolNames.contains(p.name) {
                guard Self.hasXcodeServiceAncestor(p, byPid) else { continue }
                found = true
                if project == nil, p.name != "sh", p.name != "bash", p.name != "zsh" {
                    project = Self.derivedDataProject(pid: p.pid)
                }
                if project != nil { break }
            }
            if found { activity = XcodeActivity(project: project ?? lastActivity?.project) }
        }
        consecutiveActive = activity == nil ? 0 : consecutiveActive + 1
        // Require two consecutive hits to avoid flashing for background indexing blips.
        let reported: XcodeActivity? = consecutiveActive >= 2 ? activity : nil
        if reported != lastActivity {
            lastActivity = reported
            DispatchQueue.main.async { [onActivity] in onActivity(reported) }
        }
    }

    private static func hasXcodeServiceAncestor(_ p: Proc, _ byPid: [Int32: Proc]) -> Bool {
        var cur = p
        for _ in 0..<6 {
            guard let parent = byPid[cur.ppid] else { return false }
            if serviceNames.contains(parent.name) {
                // Builds started from Xcode.app only (xcodebuild CLI is reported via ndrun / manifest).
                return byPid[parent.ppid]?.name == "Xcode"
            }
            cur = parent
        }
        return false
    }

    private static func listProcesses() -> [Proc] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        var result: [Proc] = []
        result.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            result.append(Proc(pid: pid, ppid: Int32(info.pbi_ppid), name: name))
        }
        return result
    }

    /// Reads a process's argv via KERN_PROCARGS2 and extracts `<Project>` from `DerivedData/<Project>-<hash>/`.
    private static func derivedDataProject(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buf.prefix(size).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
        guard let r = text.range(of: "DerivedData/") else { return nil }
        let rest = text[r.upperBound...]
        let folder = rest.prefix { $0 != "/" && $0 != " " }
        return projectName(fromDerivedDataFolder: String(folder))
    }

    static func projectName(fromDerivedDataFolder folder: String) -> String {
        if let dash = folder.lastIndex(of: "-"), folder.distance(from: dash, to: folder.endIndex) == 29 {
            return String(folder[..<dash])
        }
        return folder
    }

    // MARK: Manifests

    private func scanManifests() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil) else { return }
        var fresh: [XcodeLogEntry] = []
        for dir in dirs {
            let buildLogs = dir.appendingPathComponent("Logs/Build")
            let manifest = buildLogs.appendingPathComponent("LogStoreManifest.plist")
            guard let attrs = try? fm.attributesOfItem(atPath: manifest.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if mtimes[manifest.path] == mtime { continue }
            mtimes[manifest.path] = mtime
            guard let data = try? Data(contentsOf: manifest),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let logs = plist["logs"] as? [String: [String: Any]] else { continue }
            let project = Self.projectName(fromDerivedDataFolder: dir.lastPathComponent)
            for (key, log) in logs {
                let uuid = (log["uniqueIdentifier"] as? String) ?? key
                if seen.contains(uuid) { continue }
                seen.insert(uuid)
                guard let start = log["timeStartedRecording"] as? Double,
                      let end = log["timeStoppedRecording"] as? Double else { continue }
                let obs = log["primaryObservable"] as? [String: Any] ?? [:]
                let fileName = (log["fileName"] as? String) ?? "\(uuid).xcactivitylog"
                fresh.append(XcodeLogEntry(
                    uuid: uuid,
                    project: project,
                    title: (log["title"] as? String) ?? "Build",
                    started: Date(timeIntervalSinceReferenceDate: start),
                    ended: Date(timeIntervalSinceReferenceDate: end),
                    status: (obs["highLevelStatus"] as? String) ?? "S",
                    errors: (obs["totalNumberOfErrors"] as? Int) ?? 0,
                    warnings: (obs["totalNumberOfWarnings"] as? Int) ?? 0,
                    logURL: buildLogs.appendingPathComponent(fileName),
                    isBaseline: !baselineDone))
            }
        }
        baselineDone = true
        if fresh.isEmpty { return }
        let entries = fresh
        DispatchQueue.main.async { [onEntries] in onEntries(entries) }
    }

    /// First "error:" line in an `.xcactivitylog` (gzip of the SLF stream). Blocking; call off-main.
    static func firstError(in logURL: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc", logURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 96 << 20 { p.terminate(); break }
        }
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let pattern = #"(?:([\w./+@ -]+?)(?::(\d+))(?::\d+)?: )?error: ([^\n\r\u{0}-\u{8}\"]{1,220})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let msgR = Range(m.range(at: 3), in: text) else { return nil }
        var out = String(text[msgR])
        if let fR = Range(m.range(at: 1), in: text), let lR = Range(m.range(at: 2), in: text) {
            let file = (String(text[fR]) as NSString).lastPathComponent
            out = "\(file):\(text[lR]): \(out)"
        }
        return out
    }
}
