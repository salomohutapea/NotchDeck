import Foundation
import Observation
import OSLog

enum MetroPhase: Equatable {
    case offline
    case idle
    case bundling
    case done
    case failed
}

/// Tracks one Metro dev server (one port): status polling, /events socket, progress state machine.
///
/// Wire format (verified against RN 0.84 / Metro 0.83): `ws://localhost:<port>/events` sends each Metro
/// reporter event as a bare JSON text frame (`{"type":"bundle_build_started","buildID":..,"bundleDetails":{..}}`).
/// `bundle_build_done` carries NO duration, so duration is measured locally.
@MainActor @Observable
final class MetroService: Identifiable {
    nonisolated let port: Int
    nonisolated var id: Int { port }

    private(set) var phase: MetroPhase = .offline
    private(set) var platform: String?
    private(set) var entryFile: String?
    /// Smoothed, monotonic 0...1 progress for the current build.
    private(set) var progress: Double = 0
    private(set) var transformedFiles = 0
    private(set) var totalFiles = 0
    private(set) var lastDuration: TimeInterval?
    private(set) var errorMessage: String?
    private(set) var eventsConnected = false
    /// True while a result (done/failed) should be shown in the collapsed pill (5s).
    private(set) var resultVisible = false
    private(set) var activeBuildCount = 0
    /// Debuggable targets from `POST /json/list` (refreshed with each status poll while the server is up).
    private(set) var targets: [DebugTarget] = []

    /// Called on any user-visible state change.
    var onChange: (() -> Void)?
    /// Called when a build finishes: (failed, duration).
    var onFinished: ((Bool, TimeInterval) -> Void)?

    private struct Build {
        var platform: String?
        var entry: String?
        var started: Date
        var transformed = 0
        var total = 0
    }
    private var builds: [String: Build] = [:]
    private var currentBuildID: String?
    private var targetProgress = 0.0
    private var pendingError: String?

    private let log = Logger(subsystem: "com.notchdeck", category: "Metro")
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var socketTask: Task<Void, Never>?
    private var smoothTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var ws: URLSessionWebSocketTask?
    private var isUp = false

    init(port: Int) {
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    var isBundling: Bool { phase == .bundling }
    var isLive: Bool { phase == .bundling || resultVisible }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        closeSocket()
        smoothTask?.cancel(); smoothTask = nil
        resultTask?.cancel(); resultTask = nil
        isUp = false
        builds.removeAll()
        phase = .offline
        resultVisible = false
        onChange?()
    }

    private func baseURL(scheme: String = "http") -> URL? { URL(string: "\(scheme)://localhost:\(port)") }

    // MARK: Status polling

    private func pollStatus() async {
        var up = false
        if let url = baseURL()?.appendingPathComponent("status"),
           let (data, resp) = try? await session.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           String(decoding: data, as: UTF8.self).contains("packager-status:running") {
            up = true
        }
        if Task.isCancelled { return }
        if up {
            if !isUp {
                isUp = true
                log.info("Metro :\(self.port) is running")
                if phase == .offline { phase = .idle; onChange?() }
            }
            openSocketIfNeeded()
            await refreshTargets()
        } else if isUp || phase != .offline {
            isUp = false
            log.info("Metro :\(self.port) went offline")
            closeSocket()
            builds.removeAll(); currentBuildID = nil
            smoothTask?.cancel(); smoothTask = nil
            resultVisible = false
            phase = .offline
            if !targets.isEmpty { targets = [] }
            onChange?()
        }
    }

    // MARK: Events socket

    private func openSocketIfNeeded() {
        guard socketTask == nil else { return }
        socketTask = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.runSocket()
                if Task.isCancelled { return }
                backoff = ok ? 1 : min(backoff * 2, 15)
                try? await Task.sleep(for: .seconds(backoff))
                if !self.isUp { break }
            }
            self?.socketTask = nil
        }
    }

    private func closeSocket() {
        socketTask?.cancel(); socketTask = nil
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        if eventsConnected { eventsConnected = false }
    }

    /// Returns true if the socket connected and received at least one frame or opened cleanly.
    private func runSocket() async -> Bool {
        guard let url = baseURL(scheme: "ws")?.appendingPathComponent("events") else { return false }
        let task = session.webSocketTask(with: url)
        ws = task
        task.resume()
        var connected = false
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                if !connected { connected = true; eventsConnected = true; log.info("events socket connected :\(self.port)") }
                switch msg {
                case .string(let s): handleFrame(Data(s.utf8))
                case .data(let d): handleFrame(d)
                @unknown default: break
                }
            } catch {
                break
            }
        }
        eventsConnected = false
        task.cancel(with: .goingAway, reason: nil)
        if ws === task { ws = nil }
        log.info("events socket closed :\(self.port)")
        return connected
    }

    // MARK: Event parsing

    func handleFrame(_ data: Data) {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Defensive: unwrap {"event": {...}} / {"params": {...}} envelopes if type is missing.
        if obj["type"] == nil {
            if let inner = obj["event"] as? [String: Any] { obj = inner }
            else if let inner = obj["params"] as? [String: Any], inner["type"] != nil { obj = inner }
        }
        guard let type = obj["type"] as? String else {
            #if DEBUG
            log.debug("unknown frame shape: \(String(decoding: data.prefix(200), as: UTF8.self), privacy: .public)")
            #endif
            return
        }
        let buildID = obj["buildID"] as? String ?? "default"
        switch type {
        case "bundle_build_started":
            if obj["isPrefetch"] as? Bool == true { return }
            let details = obj["bundleDetails"] as? [String: Any]
            let entry = (details?["entryFile"] as? String).map { ($0 as NSString).lastPathComponent }
            builds[buildID] = Build(platform: details?["platform"] as? String, entry: entry, started: Date())
            beginDisplay(buildID)
            log.info("build started \(buildID, privacy: .public) \(self.platform ?? "?", privacy: .public)")
        case "bundle_transform_progressed":
            guard var b = builds[buildID] else { return }
            b.transformed = (obj["transformedFileCount"] as? Int) ?? b.transformed
            b.total = (obj["totalFileCount"] as? Int) ?? b.total
            builds[buildID] = b
            if buildID == currentBuildID {
                transformedFiles = b.transformed; totalFiles = b.total
                if b.total > 0 {
                    // Monotonic: total grows as the graph is discovered, so never let the ratio retreat.
                    targetProgress = max(targetProgress, min(Double(b.transformed) / Double(b.total), 0.98))
                }
            }
        case "bundling_error":
            pendingError = Self.cleanError(obj["error"])
        case "bundle_build_failed":
            finish(buildID, failed: true)
        case "bundle_build_done":
            finish(buildID, failed: false)
        default:
            #if DEBUG
            if !["client_log", "transform_cache_reset", "unstable_server_log", "worker_stdout_chunk", "worker_stderr_chunk", "initialize_started", "initialize_done", "dep_graph_loading", "dep_graph_loaded", "bundle_save_log", "resolver_warning", "watcher_status"].contains(type) {
                log.debug("unhandled event type \(type, privacy: .public)")
            }
            #endif
        }
    }

    private func beginDisplay(_ buildID: String) {
        currentBuildID = buildID
        let b = builds[buildID]
        platform = b?.platform; entryFile = b?.entry
        progress = 0; targetProgress = 0
        transformedFiles = 0; totalFiles = 0
        errorMessage = nil; pendingError = nil
        resultVisible = false; resultTask?.cancel()
        activeBuildCount = builds.count
        phase = .bundling
        startSmoothing()
        onChange?()
    }

    private func finish(_ buildID: String, failed: Bool) {
        guard let b = builds.removeValue(forKey: buildID) else { return }
        activeBuildCount = builds.count
        let duration = Date().timeIntervalSince(b.started)
        log.info("build \(failed ? "failed" : "done", privacy: .public) in \(duration)s")
        if buildID != currentBuildID, let other = builds.keys.first {
            // A non-displayed build ended while another is still running.
            currentBuildID = other; platform = builds[other]?.platform
            onChange?(); return
        }
        if let other = builds.keys.first {
            // The displayed build ended but another is still running: switch to it, still report.
            currentBuildID = other; platform = builds[other]?.platform
            onFinished?(failed, duration)
            onChange?(); return
        }
        currentBuildID = nil
        lastDuration = duration
        platform = b.platform
        if failed {
            errorMessage = pendingError ?? "Bundle build failed"
        } else {
            errorMessage = nil
            targetProgress = 1; progress = 1
        }
        pendingError = nil
        smoothTask?.cancel(); smoothTask = nil
        phase = failed ? .failed : .done
        resultVisible = true
        resultTask?.cancel()
        resultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.resultVisible = false
            self.onChange?()
        }
        onFinished?(failed, duration)
        onChange?()
    }

    /// Eases the displayed progress toward the monotonic target (~30 Hz) while a build runs.
    private func startSmoothing() {
        smoothTask?.cancel()
        smoothTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.phase == .bundling else { return }
                let t = self.targetProgress
                if t > self.progress {
                    self.progress = min(t, self.progress + max((t - self.progress) * 0.12, 0.0015))
                } else if t == 0 && self.progress < 0.05 {
                    // No data yet: creep so the UI shows life.
                    self.progress += 0.0008
                }
            }
        }
    }

    private static func cleanError(_ raw: Any?) -> String? {
        guard var s = raw as? String else { return nil }
        // Strip ANSI escapes and pretty-format wrapper.
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? s
        var out = line
        if out.hasPrefix("[") && out.hasSuffix("]") { out = String(out.dropFirst().dropLast()) }
        for prefix in ["Error: ", "SyntaxError: ", "TransformError: "] where out.hasPrefix(prefix) { out = String(out.dropFirst(prefix.count)) }
        return out.isEmpty ? nil : String(out.prefix(300))
    }

    // MARK: Actions

    /// Same as pressing "r" in the dev server terminal: the events endpoint turns a command message into
    /// a server-side `messageSocket.broadcast("reload")`. Falls back to the /message socket.
    func reload() { sendCommand("reload") }
    func openDevMenu() { sendCommand("devMenu") }

    private func sendCommand(_ command: String) {
        let payload = "{\"version\":2,\"type\":\"command\",\"command\":\"\(command)\"}"
        if let ws, eventsConnected {
            ws.send(.string(payload)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.sendViaNewSocket(path: "events", payload: payload, fallback: command) }
            }
        } else {
            sendViaNewSocket(path: "events", payload: payload, fallback: command)
        }
    }

    private func sendViaNewSocket(path: String, payload: String, fallback: String?) {
        guard let url = baseURL(scheme: "ws")?.appendingPathComponent(path) else { return }
        let task = session.webSocketTask(with: url)
        task.resume()
        task.send(.string(payload)) { [weak self, log, port] error in
            if let error {
                log.error("send \(path, privacy: .public) :\(port) failed: \(error.localizedDescription, privacy: .public)")
                if let fallback { Task { @MainActor in self?.sendMessage(method: fallback) } }
            }
            // Give the server a moment to broadcast before closing.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { task.cancel(with: .normalClosure, reason: nil) }
        }
    }

    /// Legacy path: `/message` relays `{"version":2,"method":...}` to connected apps.
    private func sendMessage(method: String) {
        sendViaNewSocket(path: "message", payload: "{\"version\":2,\"method\":\"\(method)\"}", fallback: nil)
    }

    // MARK: DevTools targets

    func refreshTargets() async {
        guard let url = baseURL()?.appendingPathComponent("json/list") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let list = DebugTarget.labelled(arr.compactMap(DebugTarget.init(json:)))
        if list != targets { targets = list; onChange?() }
    }

    /// Mirrors OpenDebuggerKeyboardHandler: `POST /open-debugger?target=<id>`.
    func openDevTools(target: DebugTarget) {
        guard var comps = URLComponents(url: baseURL()!.appendingPathComponent("open-debugger"), resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = [URLQueryItem(name: "target", value: target.id)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let s = session, log = log, port = port
        Task.detached {
            do {
                let (_, resp) = try await s.data(for: req)
                log.info("open-debugger :\(port) -> \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            } catch {
                log.error("open-debugger :\(port) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// One target opens directly; several need the picker (handled by the UI). Refreshes the list first.
    func openDevToolsIfSingle() async {
        await refreshTargets()
        if targets.count == 1 { openDevTools(target: targets[0]) }
    }
}

struct DebugTarget: Equatable, Identifiable {
    let id: String
    let title: String
    let description: String
    let deviceName: String
    /// Display label, disambiguated across the list (see `labelled`).
    var label: String = ""

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        title = json["title"] as? String ?? id
        description = json["description"] as? String ?? ""
        deviceName = json["deviceName"] as? String ?? ""
        label = title
    }

    /// "deviceName - title"; duplicates get the description (like the CLI), then a numeric id suffix.
    static func labelled(_ list: [DebugTarget]) -> [DebugTarget] {
        var out = list
        func base(_ t: DebugTarget) -> String { t.deviceName.isEmpty ? t.title : "\(t.deviceName) \u{2014} \(t.title)" }
        let titleCounts = Dictionary(grouping: list, by: { base($0) }).mapValues(\.count)
        for i in out.indices {
            var l = base(out[i])
            if titleCounts[l, default: 0] > 1, !out[i].description.isEmpty { l += " (\(out[i].description))" }
            out[i].label = l
        }
        let labelCounts = Dictionary(grouping: out, by: \.label).mapValues(\.count)
        for i in out.indices where labelCounts[out[i].label, default: 0] > 1 {
            let suffix = out[i].id.split(separator: "-").last.map(String.init) ?? out[i].id
            out[i].label += " #\(suffix)"
        }
        return out
    }
}
