import SwiftUI
import Observation
import AppKit

/// "Devtools" module (ModuleID `.metro`): dev server control (Metro detection + owned pty process)
/// and a configurable list of commands.
@MainActor @Observable
final class MetroModule: NotchModule {
    let id: ModuleID = .metro
    var preferredExpandedSize: CGSize { terminalID != nil ? NotchMetrics.terminalContentSize : NotchMetrics.expandedContentSize }
    var isLive = false
    var compactPriority = 0

    private(set) var services: [MetroService] = []
    let runner = CommandRunner()

    var commands: [DevCommand] {
        didSet {
            guard commands != oldValue else { return }
            DevCommand.save(commands)
            if started { reconcile() }
        }
    }
    var ports: [Int] {
        didSet {
            guard ports != oldValue else { return }
            UserDefaults.standard.set(ports, forKey: Self.portsKey)
            if started { reconcile() }
        }
    }
    var peekOnFinish: Bool {
        didSet { UserDefaults.standard.set(peekOnFinish, forKey: Self.peekKey) }
    }

    /// Most recent finished task, shown in the collapsed pill for a few seconds and in the peek.
    struct TaskResult: Equatable {
        var name: String
        var symbol: String
        var ok: Bool
        var duration: TimeInterval
        var message: String?
        var at: Date
    }
    /// Command whose live output is shown inside the notch (nil = normal Devtools layout).
    private(set) var terminalID: String?
    var terminalCommand: DevCommand? { terminalID.flatMap { id in commands.first { $0.id == id } } }
    func showTerminal(_ cmd: DevCommand) { terminalID = cmd.id }
    func closeTerminal() { terminalID = nil }
    private(set) var taskResult: TaskResult?
    private(set) var taskResultVisible = false

    static let portsKey = "metro.ports"
    static let peekKey = "metro.peekOnFinish"
    private var started = false
    private var resultTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        let saved = (d.array(forKey: Self.portsKey) as? [Int]) ?? [8081]
        ports = saved
        peekOnFinish = d.object(forKey: Self.peekKey) as? Bool ?? true
        commands = DevCommand.load()
    }

    // MARK: Derived state

    /// The service shown in the collapsed pill: bundling first, then recent result.
    var primary: MetroService? {
        services.first { $0.isBundling } ?? services.first { $0.resultVisible } ?? services.first { $0.phase != .offline } ?? services.first
    }
    /// One dev server: a watched port plus the dev-server command that serves it (if any).
    struct DevServer: Identifiable {
        let service: MetroService
        /// The command Start runs: the running one, else the one picked in the switcher, else the first.
        let command: DevCommand?
        /// All dev-server commands for this port (alternatives such as different bundle modes).
        let commands: [DevCommand]
        var id: Int { service.port }
        var port: Int { service.port }
    }

    var devServerCommands: [DevCommand] { commands.filter { $0.kind == .devServer } }

    /// Every watched port, in order: dev-server commands first, then extra ports from settings.
    var servers: [DevServer] {
        services.map { s in
            let cmds = devServerCommands.filter { $0.serverPort == s.port }
            let running = cmds.first { runner.isRunning($0.id) }
            let picked = activeServerIDs[s.port].flatMap { id in cmds.first { $0.id == id } }
            return DevServer(service: s, command: running ?? picked ?? cmds.first, commands: cmds)
        }
    }

    /// Port -> id of the dev-server command chosen in the switcher.
    private(set) var activeServerIDs: [Int: String] = {
        let raw = UserDefaults.standard.dictionary(forKey: "metro.activeServers") as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }()

    /// Pick which dev-server command a port uses. If another one for that port is running, it is
    /// stopped and the new one started in its place.
    func choose(_ cmd: DevCommand, for server: DevServer) {
        activeServerIDs[server.port] = cmd.id
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: activeServerIDs.map { (String($0.key), $0.value) }),
                                  forKey: "metro.activeServers")
        guard let running = server.commands.first(where: { runner.isRunning($0.id) }), running.id != cmd.id else { return }
        runner.stop(running.id)
        Task { [weak self] in
            // Give the old server a moment to release the port.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if !self.runner.isRunning(running.id) { break }
            }
            try? await Task.sleep(for: .milliseconds(500))
            self?.run(cmd)
        }
    }

    func owns(_ server: DevServer) -> Bool { server.command.map { runner.isRunning($0.id) } ?? false }
    func isReachable(_ server: DevServer) -> Bool { server.service.phase != .offline }
    /// Something answers on the port but it is not ours.
    func isExternal(_ server: DevServer) -> Bool { isReachable(server) && !owns(server) }

    var taskCommands: [DevCommand] { commands.filter { $0.kind != .devServer } }

    var runningLongTask: (cmd: DevCommand, since: Date)? {
        for c in commands where c.kind == .task {
            if let d = runner.run(for: c.id)?.startedAtDate { return (c, d) }
        }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        started = true
        runner.onChange = { [weak self] in self?.recompute() }
        runner.onFinished = { [weak self] cmd, state in self?.commandFinished(cmd, state) }
        runner.reapStale()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runner.terminateAll() }
        }
        reconcile()
    }

    func stop() {
        started = false
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o); terminateObserver = nil }
        runner.terminateAll()
        runner.onChange = nil; runner.onFinished = nil
        resultTask?.cancel()
        taskResultVisible = false
        services.forEach { $0.stop(); $0.onChange = nil; $0.onFinished = nil }
        services = []
        recompute()
    }

    private func reconcile() {
        let all = devServerCommands.map(\.serverPort) + ports
        let wanted = Array(NSOrderedSet(array: all)) as? [Int] ?? all
        for s in services where !wanted.contains(s.port) { s.stop(); s.onChange = nil; s.onFinished = nil }
        services = wanted.map { port in
            if let existing = services.first(where: { $0.port == port }) { return existing }
            let s = MetroService(port: port)
            s.onChange = { [weak self] in self?.recompute() }
            s.onFinished = { [weak self] failed, duration in
                guard let self, self.peekOnFinish else { return }
                if failed || duration > 3 {
                    self.peekIsTask = false
                    NotchCoordinator.shared.peek(.metro, duration: 4)
                }
            }
            return s
        }
        services.forEach { $0.start() }
        recompute()
    }

    private var peekIsTask = false

    private func recompute() {
        let live = services.contains { $0.isLive } || runningLongTask != nil || taskResultVisible
        if isLive != live { isLive = live }
        let prio: Int
        if services.contains(where: { $0.isBundling }) { prio = 90 }
        else if runningLongTask != nil || taskResultVisible { prio = 70 }
        else { prio = live ? 80 : 0 }
        if compactPriority != prio { compactPriority = prio }
    }

    private func commandFinished(_ cmd: DevCommand, _ state: RunState) {
        guard cmd.kind == .task else { return }
        let r: TaskResult
        switch state {
        case .succeeded(let d): r = TaskResult(name: cmd.name, symbol: cmd.symbol, ok: true, duration: d, message: nil, at: Date())
        case .failed(_, let m, let d): r = TaskResult(name: cmd.name, symbol: cmd.symbol, ok: false, duration: d, message: m, at: Date())
        default: return
        }
        taskResult = r
        taskResultVisible = true
        resultTask?.cancel()
        resultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.taskResultVisible = false
            self.recompute()
        }
        recompute()
        if peekOnFinish && (!r.ok || r.duration > 3) {
            peekIsTask = true
            NotchCoordinator.shared.peek(.metro, duration: 4)
        }
    }

    // MARK: Actions

    /// Same effect as pressing "r" in the dev server terminal.
    func reload(_ server: DevServer) {
        if let c = server.command, owns(server) { runner.send(c.id, text: "r") }
        else { server.service.reload() }
    }

    func openDevMenu(_ server: DevServer) {
        if let c = server.command, owns(server) { runner.send(c.id, text: "d") }
        else { server.service.openDevMenu() }
    }

    func openDevTools(_ target: DebugTarget, on server: DevServer) { server.service.openDevTools(target: target) }

    func openDevToolsSingle(_ server: DevServer) {
        Task { await server.service.openDevToolsIfSingle() }
    }

    func start(_ server: DevServer) {
        guard let c = server.command, !isExternal(server) else { return }
        run(c)
    }

    func stop(_ server: DevServer) {
        if let c = server.command { runner.stop(c.id) }
    }

    func run(_ cmd: DevCommand) {
        if cmd.openInTerminal {
            TerminalLauncher.run(command: cmd.command, in: cmd.expandedCwd)
            return
        }
        runner.start(cmd)
        // Launchers just open something; no output worth showing.
        if cmd.kind != .launcher { terminalID = cmd.id }
    }

    func stop(_ cmd: DevCommand) { runner.stop(cmd.id) }

    func openLog(_ cmd: DevCommand) {
        let url = CommandRunner.logURL(for: cmd.id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        TerminalLauncher.run(command: "tail -n 300 -f \(TerminalLauncher.shellQuote(url.path))", in: nil)
    }

    // MARK: NotchModule

    func compactLeading() -> AnyView { AnyView(MetroCompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(MetroCompactTrailing(module: self)) }
    func expanded() -> AnyView { AnyView(DevtoolsExpandedView(module: self)) }
    func dashboardSection() -> AnyView? { AnyView(DevtoolsDashboardView(module: self)) }
    func settings() -> AnyView? { AnyView(MetroSettingsView(module: self)) }
    func peekContent() -> AnyView? {
        if peekIsTask, let r = taskResult { return AnyView(DevtoolsTaskPeekRow(result: r)) }
        let s = services.first { $0.phase == .failed || $0.phase == .done } ?? primary
        guard let s else { return nil }
        return AnyView(MetroPeekRow(service: s))
    }
}

enum TerminalLauncher {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func asEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `tell application "Terminal" to do script "cd <dir> && <cmd>"` + activate.
    static func run(command: String, in dir: String?) {
        let line = dir.map { "cd \(shellQuote($0)) && \(command)" } ?? command
        let script = "tell application \"Terminal\"\n activate\n do script \"\(asEscape(line))\"\nend tell"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}
