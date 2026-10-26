import Foundation
import Observation
import OSLog

enum RunState: Equatable {
    case idle
    case running(pid: Int32, startedAt: Date)
    case succeeded(duration: TimeInterval)
    case failed(exitCode: Int32, message: String?, duration: TimeInterval)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

/// Writes BuildStatus spool records in the exact format `BuildSpool` / `ndrun` use.
enum BuildSpoolWriter {
    static var directory: URL {
        if let o = ProcessInfo.processInfo.environment["NOTCHDECK_SPOOL"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchDeck/builds", isDirectory: true)
    }

    static func recordID(pid: Int32, startedAt: Date) -> String { "\(Int(startedAt.timeIntervalSince1970))-\(pid)" }

    private static func write(_ name: String, _ obj: [String: Any]) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let tmp = dir.appendingPathComponent(".\(name).tmp")
        let dst = dir.appendingPathComponent(name)
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func common(id: String, title: String, cwd: String, startedAt: Date) -> [String: Any] {
        ["v": 1, "id": id, "startId": id, "source": "cli",
         "project": (cwd as NSString).lastPathComponent, "title": title, "cwd": cwd,
         "startedAt": (startedAt.timeIntervalSince1970 * 1000).rounded() / 1000]
    }

    static func start(id: String, title: String, cwd: String, pid: Int32, startedAt: Date) {
        var o = common(id: id, title: title, cwd: cwd, startedAt: startedAt)
        o["kind"] = "start"; o["pid"] = Int(pid)
        write("\(id).start.json", o)
    }

    static func done(id: String, title: String, cwd: String, startedAt: Date, exit: Int32, tail: String?) {
        var o = common(id: id, title: title, cwd: cwd, startedAt: startedAt)
        o["kind"] = "done"; o["endedAt"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        o["exit"] = Int(exit)
        if exit != 0, let tail, !tail.isEmpty { o["tail"] = tail }
        write("\(id).done.json", o)
    }
}

/// One command's current/last run. Lives in `CommandRunner.runs`.
@MainActor @Observable
final class CommandRun {
    let command: DevCommand
    private(set) var state: RunState = .idle
    /// Last few display lines (throttled) for inline previews.
    private(set) var tail: [String] = []
    private(set) var finishedAt: Date?
    /// Bumped whenever the full output changes (throttled); views read it to refresh `allLines`.
    private(set) var revision = 0
    let logURL: URL

    @ObservationIgnored fileprivate var proc: PTYProcess?
    @ObservationIgnored fileprivate var ring: [TermLine] = []
    @ObservationIgnored fileprivate var tailDirty = false
    @ObservationIgnored fileprivate var spoolID: String?
    @ObservationIgnored fileprivate var startedAt = Date()
    @ObservationIgnored fileprivate var stopRequested = false
    @ObservationIgnored fileprivate var escalation: Task<Void, Never>?
    @ObservationIgnored fileprivate var tailTask: Task<Void, Never>?

    static let ringLimit = 2000

    init(command: DevCommand, logURL: URL) {
        self.command = command
        self.logURL = logURL
    }

    var pid: Int32? { if case .running(let p, _) = state { return p }; return nil }
    var startedAtDate: Date? { if case .running(_, let d) = state { return d }; return nil }
    var allLines: [String] { ring.map(\.text) }
    /// Output with colours, for the terminal view.
    var styledLines: [TermLine] { ring }

    fileprivate func setState(_ s: RunState) { if state != s { state = s } }
    fileprivate func setFinished(_ d: Date?) { finishedAt = d }

    fileprivate func append(_ lines: [String], partial p: String) {
        let all = lines + (p.isEmpty ? [] : [p])
        if !all.isEmpty {
            ring.append(contentsOf: all.map(TermLine.plain))
            if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
        }
        refreshTailSoon()
    }

    /// Replace the whole output with the emulated terminal screen (progress bars update in place).
    fileprivate func setScreen(_ lines: [TermLine]) {
        ring = lines.count > Self.ringLimit ? Array(lines.suffix(Self.ringLimit)) : lines
        refreshTailSoon()
    }

    private func refreshTailSoon() {
        guard tailTask == nil else { tailDirty = true; return }
        refreshTail()
        tailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.tailTask = nil
            if self.tailDirty { self.tailDirty = false; self.refreshTail() }
        }
    }

    fileprivate func refreshTail() {
        let lines = ring.suffix(40).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let t = Array(lines.suffix(3))
        if t != tail { tail = t }
        revision &+= 1
    }

    fileprivate func resetOutput() {
        ring = []; tail = []; revision &+= 1
    }

    /// Last line that looks like an error, else the last non-empty line.
    func lastErrorLine() -> String? {
        let lines = ring.suffix(200).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pat = try? NSRegularExpression(pattern: "error|fail|fatal|denied|not found|no such|cannot|exception|\\*\\*\\*|stop\\.", options: [.caseInsensitive])
        for l in lines.reversed() {
            if let pat, pat.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { return String(l.prefix(300)) }
        }
        return lines.last.map { String($0.prefix(300)) }
    }
}

/// Runs configured commands under `/bin/zsh -ilc` in a pty, owns their lifecycle and keeps pidfiles
/// so a stale owned process (app crash) can be reaped on the next launch.
@MainActor @Observable
final class CommandRunner {
    private(set) var runs: [String: CommandRun] = [:]

    /// Called when a run ends (not for stop requested by the user on launchers).
    @ObservationIgnored var onFinished: ((DevCommand, RunState) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let log = Logger(subsystem: "com.notchdeck", category: "Devtools")

    static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchDeck", isDirectory: true)
    }
    static var logsDir: URL { appSupport.appendingPathComponent("logs", isDirectory: true) }
    static var runDir: URL { appSupport.appendingPathComponent("run", isDirectory: true) }

    static func logURL(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return logsDir.appendingPathComponent("\(safe).log")
    }

    func run(for id: String) -> CommandRun? { runs[id] }
    func state(for id: String) -> RunState { runs[id]?.state ?? .idle }
    func isRunning(_ id: String) -> Bool { runs[id]?.state.isRunning ?? false }
    var anyRunning: Bool { runs.values.contains { $0.state.isRunning } }

    // MARK: Start

    @discardableResult
    func start(_ cmd: DevCommand) -> Bool {
        if isRunning(cmd.id) { return false }
        let run = CommandRun(command: cmd, logURL: Self.logURL(for: cmd.id))
        run.resetOutput()
        let cwd = cmd.expandedCwd
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            runs[cmd.id] = run
            run.append(["Working directory not found: \(cwd)"], partial: "")
            run.setState(.failed(exitCode: 127, message: "Working directory not found: \(cwd)", duration: 0))
            run.setFinished(Date())
            onChange?(); onFinished?(cmd, run.state)
            return false
        }
        let header = "$ \(cmd.command)\n# cwd: \(cwd)\n"
        do {
            let p = try PTYProcess.spawn(command: cmd.command, cwd: cwd, logURL: run.logURL, logHeader: header)
            run.proc = p
            run.startedAt = Date()
            run.stopRequested = false
            run.setFinished(nil)
            run.setState(.running(pid: p.pid, startedAt: run.startedAt))
            runs[cmd.id] = run
            writePidfile(cmd, pid: p.pid, startedAt: run.startedAt)
            if cmd.trackAsBuild {
                let sid = BuildSpoolWriter.recordID(pid: p.pid, startedAt: run.startedAt)
                run.spoolID = sid
                BuildSpoolWriter.start(id: sid, title: cmd.name, cwd: cwd, pid: p.pid, startedAt: run.startedAt)
            }
            p.onScreen = { [weak run] snap in run?.setScreen(snap) }
            p.onExit = { [weak self, weak run] code in
                guard let self, let run else { return }
                self.handleExit(run, code: code)
            }
            onChange?()
            return true
        } catch {
            runs[cmd.id] = run
            let msg = error.localizedDescription
            run.append([msg], partial: "")
            run.setState(.failed(exitCode: 127, message: msg, duration: 0))
            run.setFinished(Date())
            onChange?(); onFinished?(cmd, run.state)
            return false
        }
    }

    private func handleExit(_ run: CommandRun, code: Int32) {
        run.escalation?.cancel(); run.escalation = nil
        run.proc = nil
        let duration = Date().timeIntervalSince(run.startedAt)
        removePidfile(run.command.id)
        let stopped = run.stopRequested
        // A user stop of a dev server is not a failure.
        let ok = code == 0 || (stopped && run.command.kind == .devServer)
        let state: RunState
        if ok { state = .succeeded(duration: duration) }
        else { state = .failed(exitCode: code, message: stopped ? "Stopped" : run.lastErrorLine(), duration: duration) }
        run.refreshTail()
        run.setState(state)
        run.setFinished(Date())
        if let sid = run.spoolID {
            let tail = run.allLines.suffix(20).joined(separator: "\n")
            BuildSpoolWriter.done(id: sid, title: run.command.name, cwd: run.command.expandedCwd,
                                  startedAt: run.startedAt, exit: ok ? 0 : code, tail: tail)
            run.spoolID = nil
        }
        log.info("\(run.command.name, privacy: .public) exited \(code)")
        onChange?()
        if !stopped { onFinished?(run.command, state) }
    }

    // MARK: Input / stop

    func send(_ id: String, text: String) { runs[id]?.proc?.write(text) }
    func resize(_ id: String, cols: Int, rows: Int) {
        runs[id]?.proc?.resize(cols: UInt16(clamping: max(20, cols)), rows: UInt16(clamping: max(5, rows)))
    }

    /// SIGINT -> (3s) SIGTERM -> (3s) SIGKILL, process group + descendants.
    func stop(_ id: String) {
        guard let run = runs[id], let p = run.proc, run.escalation == nil else { return }
        run.stopRequested = true
        p.sendCtrlC()
        run.escalation = Task { [weak run] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let run, let p = run.proc, !p.hasExited else { return }
            p.signalAll(SIGTERM)
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let p = run.proc, !p.hasExited else { return }
            p.signalAll(SIGKILL)
        }
    }

    /// Synchronous teardown for app quit / module stop. Records interrupted builds as failed.
    func terminateAll() {
        for run in runs.values {
            guard let p = run.proc else { continue }
            run.escalation?.cancel()
            run.stopRequested = true
            p.onExit = nil; p.onScreen = nil
            p.signalAll(SIGTERM)
        }
        let live = runs.values.filter { $0.proc != nil }
        if !live.isEmpty { usleep(250_000) }
        for run in live {
            guard let p = run.proc else { continue }
            p.signalAll(SIGKILL)
            if let sid = run.spoolID {
                BuildSpoolWriter.done(id: sid, title: run.command.name, cwd: run.command.expandedCwd,
                                      startedAt: run.startedAt, exit: 143, tail: "Interrupted: NotchDeck quit")
                run.spoolID = nil
            }
            removePidfile(run.command.id)
            run.proc = nil
            run.setState(.idle)
        }
        onChange?()
    }

    // MARK: Pidfiles

    private struct PidInfo: Codable { var pid: Int32; var startedAt: Double; var owner: Int32; var command: String }

    private func pidfile(_ id: String) -> URL {
        Self.runDir.appendingPathComponent(Self.logURL(for: id).deletingPathExtension().lastPathComponent + ".pid")
    }

    private func writePidfile(_ cmd: DevCommand, pid: Int32, startedAt: Date) {
        try? FileManager.default.createDirectory(at: Self.runDir, withIntermediateDirectories: true)
        let info = PidInfo(pid: pid, startedAt: startedAt.timeIntervalSince1970, owner: getpid(), command: cmd.command)
        if let d = try? JSONEncoder().encode(info) { try? d.write(to: pidfile(cmd.id)) }
    }

    private func removePidfile(_ id: String) { try? FileManager.default.removeItem(at: pidfile(id)) }

    /// Kills processes left behind by a previous NotchDeck that crashed (owner dead, pid still alive and still the same process).
    /// Returns the commands' names that were reaped.
    @discardableResult
    func reapStale() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.runDir, includingPropertiesForKeys: nil) else { return [] }
        var reaped: [String] = []
        for f in files where f.pathExtension == "pid" {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let d = try? Data(contentsOf: f), let info = try? JSONDecoder().decode(PidInfo.self, from: d) else { continue }
            if info.owner != getpid(), kill(info.owner, 0) == 0 { continue }   // another live NotchDeck owns it
            guard info.pid > 1, kill(info.pid, 0) == 0 else { continue }
            // Guard against pid reuse: the process must have started when we recorded it (zsh may have exec'd the tool).
            var bsd = proc_bsdinfo()
            let sz = proc_pidinfo(info.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard sz > 0, abs(Double(bsd.pbi_start_tvsec) - info.startedAt) <= 5 else { continue }
            killpg(info.pid, SIGTERM)
            for c in PTYProcess.descendants(of: info.pid) { kill(c, SIGTERM) }
            let pid = info.pid
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { killpg(pid, SIGKILL); for c in PTYProcess.descendants(of: pid) { kill(c, SIGKILL) } }
            }
            reaped.append(info.command)
            log.info("reaped stale process \(info.pid) (\(info.command, privacy: .public))")
        }
        return reaped
    }
}
