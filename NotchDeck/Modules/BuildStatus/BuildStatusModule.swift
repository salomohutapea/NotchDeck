import SwiftUI
import Observation
import AppKit
@preconcurrency import UserNotifications

@MainActor @Observable
final class BuildStatusModule: NotchModule {
    let id: ModuleID = .buildStatus
    var isLive = false
    var compactPriority = 0

    private(set) var builds: [BuildRecord] = []

    // Settings (UserDefaults-backed, prefix "buildStatus.")
    var xcodeDetection: Bool {
        didSet {
            UserDefaults.standard.set(xcodeDetection, forKey: Keys.xcode)
            if started { applyXcodeDetection() }
        }
    }
    var peekThreshold: Double {
        didSet { UserDefaults.standard.set(peekThreshold, forKey: Keys.peekThreshold) }
    }
    var notifyOnFinish: Bool {
        didSet { UserDefaults.standard.set(notifyOnFinish, forKey: Keys.notify) }
    }
    var installMessage: String?
    private(set) var ndrunInstalled = false
    private(set) var ndrunUpToDate = false
    private(set) var gradleInstalled = false

    enum Keys {
        static let xcode = "buildStatus.xcodeDetection"
        static let peekThreshold = "buildStatus.peekThreshold"
        static let notify = "buildStatus.notify"
        static let history = "buildStatus.history"
        static let taskCounts = "buildStatus.taskCounts"
        static let clearedAt = "buildStatus.clearedAt"
    }

    @ObservationIgnored private let spool = BuildSpool()
    @ObservationIgnored private let gradleWatcher = GradleDaemonWatcher()
    @ObservationIgnored private let xcode = XcodeWatcher()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var history: [String: [Double]]
    @ObservationIgnored private var counted = Set<String>()
    /// Final Gradle task count of the last successful build per history key (denominator for live progress).
    @ObservationIgnored private var taskCounts: [String: Int]
    @ObservationIgnored private var seededKeys = Set<String>()
    @ObservationIgnored private var clearedAt: Date
    @ObservationIgnored private var finishWindowUntil = Date.distantPast
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var xcodeEndTask: Task<Void, Never>?
    @ObservationIgnored private let launchedAt = Date()

    static let xcodeLiveID = "xcode-live"
    static let resultWindow: TimeInterval = 6
    static let maxBuilds = 30
    static let maxShown = 5

    init() {
        let d = UserDefaults.standard
        xcodeDetection = d.object(forKey: Keys.xcode) as? Bool ?? true
        peekThreshold = d.object(forKey: Keys.peekThreshold) as? Double ?? 5
        notifyOnFinish = d.object(forKey: Keys.notify) as? Bool ?? true
        clearedAt = Date(timeIntervalSince1970: d.double(forKey: Keys.clearedAt))
        history = (d.dictionary(forKey: Keys.history) as? [String: [Double]]) ?? [:]
        taskCounts = (d.dictionary(forKey: Keys.taskCounts) as? [String: Int]) ?? [:]
        spool.onRecords = { [weak self] recs in self?.ingest(recs) }
        gradleWatcher.onStart = { [weak self] b in self?.daemonBuildStarted(b) }
        gradleWatcher.onFinish = { [weak self] b in self?.daemonBuildFinished(b) }
        spool.onOrphans = { [weak self] recs in self?.ingestOrphans(recs) }
        xcode.onActivity = { [weak self] a in self?.xcodeActivity(a) }
        xcode.onEntries = { [weak self] e in self?.xcodeEntries(e) }
    }

    // MARK: Lifecycle

    func start() {
        started = true
        spool.start()
        gradleWatcher.start()
        applyXcodeDetection()
        refreshInstallStatus()
    }

    func stop() {
        started = false
        spool.stop()
        gradleWatcher.stop()
        xcode.stop()
        windowTask?.cancel(); xcodeEndTask?.cancel()
        builds.removeAll { $0.isRunning }
        recompute()
    }

    private func applyXcodeDetection() {
        if xcodeDetection { xcode.start() } else {
            xcode.stop()
            builds.removeAll { $0.id == Self.xcodeLiveID }
            recompute()
        }
    }

    // MARK: Derived state

    var hasFinished: Bool { builds.contains { !$0.isRunning } }
    var recentBuilds: [BuildRecord] { Array(builds.prefix(Self.maxShown)) }

    /// The build shown in the collapsed pill: running first, then the latest result.
    var primaryBuild: BuildRecord? {
        builds.filter(\.isRunning).max { $0.startedAt < $1.startedAt }
            ?? builds.filter { !$0.isRunning }.max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    func averageDuration(for b: BuildRecord) -> TimeInterval? {
        guard let d = history[b.historyKey]?.suffix(5), !d.isEmpty else { return nil }
        return d.reduce(0, +) / Double(d.count)
    }

    /// 0...0.97 for a running build: finished tasks / tasks of the last successful run, else elapsed / average duration.
    func progress(for b: BuildRecord, at now: Date = Date()) -> Double? {
        guard b.isRunning else { return nil }
        if let done = b.tasksDone, let total = taskCounts[b.historyKey], total > 0 { return min(0.97, Double(done) / Double(total)) }
        if let avg = averageDuration(for: b), avg > 0 { return min(0.96, b.elapsed(at: now) / avg) }
        return nil
    }

    private func storeTaskCount(_ b: BuildRecord) {
        guard b.source == .gradle, b.status != .failed, let n = b.tasksDone, n > 0 else { return }
        taskCounts[b.historyKey] = n
        UserDefaults.standard.set(taskCounts, forKey: Keys.taskCounts)
    }

    private func recompute() {
        let running = builds.contains { $0.isRunning }
        let inWindow = Date() < finishWindowUntil
        let live = running || inWindow
        if isLive != live { isLive = live }
        let prio = running ? 95 : (inWindow ? 85 : 0)
        if compactPriority != prio { compactPriority = prio }
    }

    private func openResultWindow() {
        finishWindowUntil = Date().addingTimeInterval(Self.resultWindow)
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resultWindow + 0.1))
            guard !Task.isCancelled else { return }
            self?.windowTick &+= 1
            self?.recompute()
        }
        recompute()
    }

    // MARK: Mutations

    private func upsert(_ b: BuildRecord) {
        if let i = builds.firstIndex(where: { $0.id == b.id }) { builds[i] = b } else { builds.append(b) }
        builds.sort { ($0.isRunning ? Date.distantFuture : ($0.endedAt ?? $0.startedAt)) > ($1.isRunning ? Date.distantFuture : ($1.endedAt ?? $1.startedAt)) }
        if builds.count > Self.maxBuilds { builds.removeLast(builds.count - Self.maxBuilds) }
        recompute()   // a newly started build must turn the notch live immediately
    }

    func clear() {
        clearedAt = Date()
        UserDefaults.standard.set(clearedAt.timeIntervalSince1970, forKey: Keys.clearedAt)
        builds.removeAll { !$0.isRunning }
        recompute()
    }

    private func finished(_ b: BuildRecord) {
        upsert(b)
        storeTaskCount(b)
        let key = b.id
        if !counted.contains(key) {
            counted.insert(key)
            if b.status != .failed, let d = b.duration, d > 0.5 { addHistory(b.historyKey, d) }
        }
        // Only react to builds that finished while we were watching (not old spool leftovers).
        guard let end = b.endedAt, Date().timeIntervalSince(end) < 15, end > launchedAt.addingTimeInterval(-15) else {
            recompute(); return
        }
        openResultWindow()
        let duration = b.duration ?? 0
        if b.isFailed || duration > peekThreshold {
            NotchCoordinator.shared.peek(.buildStatus, duration: 4)
        }
        if notifyOnFinish, duration > 30 { postNotification(b) }
    }

    private func addHistory(_ key: String, _ d: Double) {
        var arr = history[key] ?? []
        arr.append(d)
        history[key] = Array(arr.suffix(8))
        UserDefaults.standard.set(history, forKey: Keys.history)
    }

    private func postNotification(_ b: BuildRecord) {
        let center = UNUserNotificationCenter.current()
        let title = b.isFailed ? "Build failed" : "Build succeeded"
        let body = "\(b.project) · \(b.title) · \(buildDuration(b.duration ?? 0))"
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    // MARK: Gradle daemon detection (covers configuration-cache hits, where the init-script hook never starts)

    private static let daemonPrefix = "gd-"

    /// A running build detected from the daemon log (no task names yet).
    private func syntheticGradle(cwd: String?) -> Int? {
        let mine = builds.indices.filter { builds[$0].isRunning && builds[$0].id.hasPrefix(Self.daemonPrefix) }
        return mine.first { builds[$0].cwd == cwd } ?? mine.first
    }

    private func daemonBuildStarted(_ e: GradleDaemonBuild) {
        let id = Self.daemonPrefix + e.buildID
        guard e.startedAt > clearedAt, !builds.contains(where: { $0.id == id }) else { return }
        // A hook start record for the same build wins (it knows the task names).
        if builds.contains(where: { $0.isRunning && $0.source == .gradle && !$0.id.hasPrefix(Self.daemonPrefix)
                                    && $0.cwd == e.dir && abs($0.startedAt.timeIntervalSince(e.startedAt)) < 30 }) { return }
        upsert(BuildRecord(id: id, source: .gradle, project: (e.dir as NSString).lastPathComponent,
                           title: "Gradle build", startedAt: e.startedAt, cwd: e.dir))
    }

    private func daemonBuildFinished(_ e: GradleDaemonBuild) {
        let id = Self.daemonPrefix + e.buildID
        // The hook's finish record (task names, result) normally arrives first; wait briefly for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, let i = self.builds.firstIndex(where: { $0.id == id && $0.isRunning }) else { return }
            self.builds[i].endedAt = Date()
            self.builds[i].status = .succeeded   // result unknown without a hook record (sync or cache-hit build)
            self.upsert(self.builds[i])
            self.openResultWindow()
        }
    }

    // MARK: Spool input (ndrun, Gradle)

    private func ingest(_ recs: [SpoolRecord]) {
        let ordered = recs.sorted { ($0.kind == "start" ? 0 : 1, $0.startedAt ?? 0) < ($1.kind == "start" ? 0 : 1, $1.startedAt ?? 0) }
        for r in ordered {
            let source = BuildSource(rawValue: r.source ?? "cli") ?? .cli
            if r.kind == "progress" {
                guard let n = r.done,
                      let i = builds.firstIndex(where: { $0.id == r.key }) ?? (source == .gradle ? syntheticGradle(cwd: r.cwd) : nil)
                else { continue }
                builds[i].tasksDone = n
                if r.last == true, !builds[i].isRunning { storeTaskCount(builds[i]) }
                continue
            }
            if r.kind == "start" {
                let started = Date(timeIntervalSince1970: r.startedAt ?? Date().timeIntervalSince1970)
                guard started > clearedAt, builds.first(where: { $0.id == r.key }) == nil else { continue }
                if source == .gradle, let j = syntheticGradle(cwd: r.cwd) { builds.remove(at: j) }
                if source != .cli, Date().timeIntervalSince(started) > 6 * 3600 { continue }
                upsert(BuildRecord(id: r.key, source: source, project: r.project ?? "Build",
                                   title: r.title ?? "", startedAt: started, cwd: r.cwd, pid: r.pid))
            } else {
                let ended = Date(timeIntervalSince1970: r.endedAt ?? Date().timeIntervalSince1970)
                guard ended > clearedAt else { continue }
                let failed = (r.exit ?? 0) != 0
                var existing = builds.first { $0.id == r.key }
                if existing == nil, source == .gradle, let j = syntheticGradle(cwd: r.cwd) {
                    // Configuration-cache hit: the hook's start record is stale; adopt the daemon-detected build.
                    var adopted = builds[j]
                    adopted.title = r.title ?? adopted.title
                    adopted.project = r.project ?? adopted.project
                    existing = adopted
                }
                var b: BuildRecord
                if let existing, existing.isRunning {
                    b = existing
                } else if let existing, existing.id == r.id { continue }   // duplicate delivery
                else {
                    let startedAt = r.startedAt.map { Date(timeIntervalSince1970: $0) } ?? ended
                    b = BuildRecord(id: r.id, source: source, project: r.project ?? "Build",
                                    title: r.title ?? "", startedAt: startedAt, cwd: r.cwd,
                                    hasStart: r.startedAt != nil)
                }
                b.endedAt = ended
                b.errors = r.errors ?? 0
                b.warnings = r.warnings ?? 0
                b.status = failed ? .failed : (b.warnings > 0 ? .warnings : .succeeded)
                if failed {
                    b.logTail = r.tail
                    b.message = r.message ?? Self.snippet(fromTail: r.tail) ?? "Exited with code \(r.exit ?? 1)"
                }
                finished(b)
            }
        }
    }

    private func ingestOrphans(_ recs: [SpoolRecord]) {
        for r in recs {
            guard var b = builds.first(where: { $0.id == r.key }), b.isRunning else { continue }
            b.endedAt = Date()
            b.status = .failed
            b.message = "Interrupted"
            finished(b)
        }
    }

    /// Best one-line explanation from the last lines of output.
    static func snippet(fromTail tail: String?) -> String? {
        guard let tail else { return nil }
        let lines = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let hit = lines.last(where: { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("failed") }) {
            return String(hit.prefix(200))
        }
        return lines.last.map { String($0.prefix(200)) }
    }

    func copyLog(of b: BuildRecord) {
        let text = b.logTail ?? b.message ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Xcode input

    private func xcodeActivity(_ a: XcodeActivity?) {
        guard xcodeDetection else { return }
        if let a {
            xcodeEndTask?.cancel()
            let project = a.project ?? "Xcode"
            if var live = builds.first(where: { $0.id == Self.xcodeLiveID }) {
                if live.project != project { live.project = project; live.title = "Build \(project)"; upsert(live) }
            } else {
                upsert(BuildRecord(id: Self.xcodeLiveID, source: .xcode, project: project, title: "Build \(project)",
                                   startedAt: Date().addingTimeInterval(-3)))
            }
            recompute()
        } else if builds.contains(where: { $0.id == Self.xcodeLiveID }) {
            // Processes are gone: the manifest entry should arrive shortly; otherwise it was cancelled.
            xcodeEndTask?.cancel()
            xcodeEndTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self else { return }
                self.builds.removeAll { $0.id == Self.xcodeLiveID }
                self.recompute()
            }
        }
    }

    private func xcodeEntries(_ entries: [XcodeLogEntry]) {
        guard xcodeDetection else { return }
        for e in entries.sorted(by: { $0.ended < $1.ended }) {
            let key = "xcode|\(e.project)"
            if e.isBaseline {
                // First run only: seed the average from builds Xcode already logged.
                let known = history[key] != nil && !seededKeys.contains(key)
                if !known, e.status != "E", e.errors == 0 {
                    seededKeys.insert(key)
                    let d = e.ended.timeIntervalSince(e.started)
                    if d > 1 { addHistory(key, d) }
                }
                continue
            }
            guard e.ended > clearedAt else { continue }
            // xcodebuild run through ndrun is already tracked as a CLI build.
            let overlapsCLI = builds.contains {
                $0.source == .cli && $0.title.contains("xcodebuild")
                    && $0.startedAt < e.ended.addingTimeInterval(15) && ($0.endedAt ?? Date()) > e.started.addingTimeInterval(-5)
            }
            builds.removeAll { $0.id == Self.xcodeLiveID }
            xcodeEndTask?.cancel()
            if overlapsCLI { recompute(); continue }
            let st = e.status.uppercased()
            if ["X", "C", "A"].contains(st) { recompute(); continue }   // cancelled / aborted
            let failed = st == "E" || e.errors > 0
            var b = BuildRecord(id: e.uuid, source: .xcode, project: e.project, title: e.title,
                                startedAt: e.started, endedAt: e.ended)
            b.errors = e.errors
            b.warnings = e.warnings
            b.status = failed ? .failed : (st == "W" || e.warnings > 0 ? .warnings : .succeeded)
            if failed { b.message = e.errors > 0 ? "\(e.errors) error\(e.errors == 1 ? "" : "s")" : "Build failed" }
            finished(b)
            if failed { loadXcodeError(for: e) }
        }
    }

    private func loadXcodeError(for e: XcodeLogEntry) {
        let url = e.logURL
        let id = e.uuid
        Task.detached(priority: .utility) { [weak self] in
            // The activity log is flushed slightly after the manifest entry; give it a moment.
            try? await Task.sleep(for: .seconds(1))
            guard let msg = XcodeWatcher.firstError(in: url) else { return }
            await MainActor.run { [weak self] in
                guard let self, var b = self.builds.first(where: { $0.id == id }) else { return }
                b.message = msg
                b.logTail = msg
                self.upsert(b)
            }
        }
    }

    // MARK: Install helpers

    func refreshInstallStatus() {
        ndrunInstalled = BuildInstallers.ndrunInstalled
        ndrunUpToDate = BuildInstallers.ndrunUpToDate
        gradleInstalled = BuildInstallers.gradleHookInstalled
    }

    func perform(_ message: String, _ work: () throws -> Void) {
        do { try work(); installMessage = message } catch { installMessage = error.localizedDescription }
        refreshInstallStatus()
    }

    // MARK: NotchModule views

    /// Bumped when the result window closes so time-based icons re-evaluate.
    private(set) var windowTick = 0

    /// One icon per platform (Android, iOS, other) that is building or just finished.
    func compactItems() -> [CompactItem] {
        _ = windowTick
        let now = Date()
        return BuildPlatform.allCases.compactMap { platform in
            let mine = builds.filter { $0.platform == platform }
            let b = mine.filter(\.isRunning).max { $0.startedAt < $1.startedAt }
                ?? mine.filter { !$0.isRunning && ($0.endedAt.map { now.timeIntervalSince($0) < Self.resultWindow } ?? false) }
                    .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
            guard let b else { return nil }
            return CompactItem(id: "build.\(platform.rawValue)", rank: platform.rank,
                               view: AnyView(BuildPlatformIcon(platform: platform, status: b.status, progress: progress(for: b, at: now))))
        }
    }

    func compactLeading() -> AnyView { AnyView(BuildCompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(BuildCompactTrailing(module: self)) }
    func expanded() -> AnyView { AnyView(BuildExpandedView(module: self)) }
    func settings() -> AnyView? { AnyView(BuildSettingsView(module: self)) }
    func peekContent() -> AnyView? {
        guard let b = builds.first(where: { !$0.isRunning }) else { return nil }
        return AnyView(BuildPeekRow(build: b))
    }
}
