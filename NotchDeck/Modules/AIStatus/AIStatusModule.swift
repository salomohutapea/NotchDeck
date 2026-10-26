import SwiftUI
import Observation
import os

@MainActor @Observable
final class AIStatusModule: NotchModule {
    enum ServerStatus: Equatable { case stopped, listening(UInt16), error(String) }

    let id: ModuleID = .aiStatus

    private(set) var sessions: [String: AISession] = [:]
    private(set) var serverStatus: ServerStatus = .stopped
    private(set) var claudeInstalled = false
    private(set) var codexInstalled = false
    var installMessage: String?
    private(set) var hasReceivedEvents = UserDefaults.standard.bool(forKey: "aiStatus.hasReceived")

    var isLive: Bool { sessions.values.contains { $0.state.isWorking || isFreshDone($0) } }
    var compactPriority: Int {
        guard let s = topSession else { return 0 }
        if case .waitingForUser = s.state { return 110 }
        return isLive ? 100 : 0
    }

    /// Most important session (waiting > working > done > idle, then most recent).
    var topSession: AISession? { orderedSessions.first }
    var orderedSessions: [AISession] {
        sessions.values.sorted {
            $0.importance != $1.importance ? $0.importance > $1.importance : $0.lastEvent > $1.lastEvent
        }
    }
    /// Number of other sessions that are not idle.
    var extraActiveCount: Int { max(0, sessions.values.filter { $0.importance > 0 }.count - 1) }

    @ObservationIgnored private let server = HookServer()
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var installer = HookInstaller.standard()
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "app.notchdeck", category: "aistatus")

    private static let doneTTL: TimeInterval = 10
    private static let staleWorking: TimeInterval = 15 * 60
    private static let dropIdle: TimeInterval = 30 * 60

    init() {}

    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "aiStatus.port")
        return (1024...65535).contains(p) ? UInt16(p) : 47474
    }

    // MARK: NotchModule

    /// One icon per agent with live sessions: Codex (OpenAI) first, then Claude.
    func compactItems() -> [CompactItem] {
        [(AIAgent.codex, 20), (AIAgent.claude, 21)].compactMap { agent, rank in
            let live = sessions.values.filter { $0.agent == agent && ($0.state.isWorking || isFreshDone($0)) }
            guard !live.isEmpty else { return nil }
            let working = live.contains { $0.state.isWorking }
            let waiting = live.contains { if case .waitingForUser = $0.state { return true }; return false }
            return CompactItem(id: "ai.\(agent.rawValue)", rank: rank,
                               view: AnyView(AIAgentCompactIcon(agent: agent, working: working, waiting: waiting)))
        }
    }

    func compactLeading() -> AnyView { AnyView(AICompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(AICompactTrailing(module: self)) }
    func expanded() -> AnyView { AnyView(AIExpandedView(module: self)) }
    func settings() -> AnyView? { AnyView(AISettingsView(module: self)) }
    func dashboardSection() -> AnyView? { AnyView(AIDashboardPane(module: self)) }
    func peekContent() -> AnyView? {
        // The session that just finished / asked for input (latest event among those).
        let s = sessions.values
            .filter { if case .done = $0.state { return true }; if case .waitingForUser = $0.state { return true }; return false }
            .max { $0.lastEvent < $1.lastEvent } ?? topSession
        guard let s else { return nil }
        return AnyView(AIPeekRow(session: s))
    }

    func start() {
        guard !started else { return }
        started = true
        server.onEvent = { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
        server.onState = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .listening(let p): self.serverStatus = .listening(p)
                case .failed(let m): self.serverStatus = .error(m)
                }
            }
        }
        server.start(port: port)
        refreshInstallStatus()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sweep(now: Date())
            }
        }
    }

    func stop() {
        started = false
        server.stop()
        sweepTask?.cancel()
        sweepTask = nil
        serverStatus = .stopped
        sessions.removeAll()
    }

    func restartServer() {
        guard started else { return }
        serverStatus = .stopped
        server.start(port: port)
    }

    // MARK: State machine

    private func isFreshDone(_ s: AISession) -> Bool {
        if case .done(let at) = s.state { return Date().timeIntervalSince(at) < Self.doneTTL }
        return false
    }

    func handle(_ ev: HookEvent, now: Date = Date()) {
        log.debug("hook \(ev.name, privacy: .public) session=\(ev.sessionID, privacy: .public)")
        if !hasReceivedEvents {
            hasReceivedEvents = true
            UserDefaults.standard.set(true, forKey: "aiStatus.hasReceived")
        }
        if ev.name == "SessionEnd" { sessions.removeValue(forKey: ev.sessionID); return }
        if ev.name == "SubagentStop" { return }

        let agent = AIAgent(rawValue: ev.agent) ?? .claude
        var s = sessions[ev.sessionID] ?? AISession(id: ev.sessionID, agent: agent, cwd: ev.cwd, prompt: nil,
                                                    state: .idle, startedAt: now, lastEvent: now)
        s.agent = agent
        if !ev.cwd.isEmpty {
            s.cwd = ev.cwd
            if s.projectName == nil { s.projectName = AISession.projectName(for: ev.cwd) }
        }
        s.lastEvent = now
        let wasIdle: Bool = { if case .idle = s.state { return true }; if case .done = s.state { return true }; return false }()
        var peek = false

        switch ev.name {
        case "SessionStart":
            if sessions[ev.sessionID] == nil { s.state = .idle }
        case "UserPromptSubmit":
            s.state = .thinking
            s.startedAt = now
            if let p = ev.prompt { s.prompt = Self.snippet(p) }
        case "PreToolUse":
            if wasIdle { s.startedAt = now }
            s.state = .tool(ev.toolLabel ?? ev.toolName ?? "Tool")
        case "PostToolUse":
            if wasIdle { s.startedAt = now }
            s.state = .thinking
        case "Notification":
            if ev.notificationType == "idle_prompt" || (ev.message ?? "").localizedCaseInsensitiveContains("waiting for your input") {
                break // "Claude is idle" nudge, not a request for the user
            }
            s.state = .waitingForUser(ev.message)
            peek = true
        case "Stop":
            s.state = .done(now)
            peek = true
        default:
            break
        }
        sessions[ev.sessionID] = s
        if sessions.count > 20, let oldest = sessions.values.min(by: { $0.lastEvent < $1.lastEvent }) {
            sessions.removeValue(forKey: oldest.id)
        }
        if peek { NotchCoordinator.shared.peek(.aiStatus) }
    }

    func sweep(now: Date) {
        for (key, s) in sessions {
            switch s.state {
            case .done(let at) where now.timeIntervalSince(at) >= Self.doneTTL:
                sessions[key]?.state = .idle
            case .thinking, .tool, .waitingForUser:
                if now.timeIntervalSince(s.lastEvent) > Self.staleWorking { sessions[key]?.state = .idle }
            case .idle:
                if now.timeIntervalSince(s.lastEvent) > Self.dropIdle { sessions.removeValue(forKey: key) }
            default: break
            }
        }
    }

    private static func snippet(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    // MARK: Installer

    func refreshInstallStatus() {
        claudeInstalled = installer.isInstalled(.claude)
        codexInstalled = installer.isInstalled(.codex)
    }

    func install(_ t: HookInstaller.Target) {
        do {
            try installer.install(t)
            installMessage = "\(t.displayName) hooks installed."
        } catch { installMessage = "Install failed: \(error.localizedDescription)" }
        refreshInstallStatus()
    }

    func uninstall(_ t: HookInstaller.Target) {
        do {
            try installer.uninstall(t)
            installMessage = "\(t.displayName) hooks removed."
        } catch { installMessage = "Uninstall failed: \(error.localizedDescription)" }
        refreshInstallStatus()
    }

    // MARK: Test event

    /// Posts a short fake session through the real HTTP server.
    func sendTestEvent() {
        guard case .listening(let p) = serverStatus else {
            installMessage = "Server is not listening; cannot send a test event."
            return
        }
        let sid = "notchdeck-test"
        let cwd = NSHomeDirectory() + "/Developer/NotchDeck"
        let steps: [(Double, [String: Any])] = [
            (0, ["hook_event_name": "UserPromptSubmit", "prompt": "Test event from NotchDeck settings"]),
            (1.5, ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "npm test"]]),
            (3.0, ["hook_event_name": "PostToolUse", "tool_name": "Bash"]),
            (4.0, ["hook_event_name": "Stop"]),
        ]
        installMessage = "Test event sent."
        for (delay, fields) in steps {
            var body = fields
            body["session_id"] = sid
            body["cwd"] = cwd
            Task.detached {
                try? await Task.sleep(for: .seconds(delay))
                guard let url = URL(string: "http://127.0.0.1:\(p)/hook?agent=claude"),
                      let data = try? JSONSerialization.data(withJSONObject: body) else { return }
                var req = URLRequest(url: url, timeoutInterval: 2)
                req.httpMethod = "POST"
                req.httpBody = data
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }
}
