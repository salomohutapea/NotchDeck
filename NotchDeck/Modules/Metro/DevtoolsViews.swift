import SwiftUI

let devCyan = Color(red: 0.25, green: 0.85, blue: 1.0)

// MARK: - Server status helpers

extension MetroModule {
    func statusColor(_ server: DevServer) -> Color {
        switch server.service.phase {
        case .offline: return owns(server) ? NotchTheme.warning : NotchTheme.tertiaryText
        case .idle, .done: return NotchTheme.success
        case .bundling: return devCyan
        case .failed: return NotchTheme.danger
        }
    }

    func statusText(_ server: DevServer) -> String {
        let s = server.service
        switch s.phase {
        case .offline: return owns(server) ? "Starting\u{2026}" : "Stopped"
        case .idle: return "Running"
        case .bundling: return "Bundling \(Int(s.progress * 100))%"
        case .done: return "Built" + (s.lastDuration.map { " in \(formatDuration($0))" } ?? "")
        case .failed: return "Build failed"
        }
    }

    /// The server the Home summary reports on: bundling, then failed / running, then the first.
    var summaryServer: DevServer? {
        let all = servers
        return all.first { $0.service.phase == .bundling } ?? all.first { $0.service.phase == .failed }
            ?? all.first { isReachable($0) || owns($0) } ?? all.first
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    t < 10 ? String(format: "%.1fs", t) : String(format: "%.0fs", t)
}

// MARK: - Small controls

struct DevIconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color = .white
    var enabled = true
    var minWidth: CGFloat = 26
    var height: CGFloat = 24
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? tint : NotchTheme.tertiaryText)
                .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(Capsule().fill(hover && enabled ? NotchTheme.surfaceStrong : NotchTheme.surface))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// DevTools: opens directly when one target is connected, otherwise a menu of targets.
struct DevToolsControl: View {
    let module: MetroModule
    let server: MetroModule.DevServer
    var fill = false
    var body: some View {
        let targets = server.service.targets
        let reachable = module.isReachable(server)
        if targets.count > 1 {
            Menu {
                ForEach(targets) { t in
                    Button(t.label) { module.openDevTools(t, on: server) }
                }
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, maxWidth: fill ? .infinity : 26, minHeight: 24, maxHeight: 24)
                    .background(Capsule().fill(NotchTheme.surface))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Open DevTools (\(targets.count) targets)")
        } else {
            DevIconButton(symbol: "ladybug", help: targets.isEmpty ? "DevTools (no connected app)" : "Open DevTools",
                          enabled: reachable && !targets.isEmpty, minWidth: 26) { module.openDevToolsSingle(server) }
        }
    }
}

struct StartStopButton: View {
    let module: MetroModule
    let server: MetroModule.DevServer
    var body: some View {
        if module.owns(server) {
            DevIconButton(symbol: "stop.fill", help: "Stop dev server", tint: NotchTheme.danger) { module.stop(server) }
        } else {
            let external = module.isExternal(server)
            DevIconButton(symbol: "play.fill",
                          help: external ? "Running outside NotchDeck" : (server.command == nil ? "No dev server command for :\(server.port)" : "Start dev server"),
                          tint: NotchTheme.success,
                          enabled: !external && server.command != nil) { module.start(server) }
        }
    }
}

/// Name of the dev server; a menu to switch between alternatives when a port has several.
struct DevServerSwitcher: View {
    let module: MetroModule
    let server: MetroModule.DevServer
    var font: Font = NotchTheme.titleFont

    var body: some View {
        let name = server.command?.name ?? "Dev server"
        if server.commands.count > 1 {
            Menu {
                ForEach(server.commands) { c in
                    Button { module.choose(c, for: server) } label: {
                        if c.id == server.command?.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(name).font(font).foregroundStyle(.white).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(NotchTheme.secondaryText)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(NotchTheme.surfaceStrong))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(module.owns(server) ? "Switch dev server (restarts it)" : "Choose which dev server Start runs")
        } else {
            Text(name).font(font).foregroundStyle(.white).lineLimit(1)
        }
    }
}

// MARK: - Task button

struct TaskButton: View {
    let module: MetroModule
    let cmd: DevCommand
    var compact = false
    @State private var hover = false

    var body: some View {
        let state = module.runner.state(for: cmd.id)
        let showState = cmd.kind == .task || state.isFailed
        Button(action: { tap(state) }) {
            HStack(spacing: 6) {
                Image(systemName: cmd.symbol)
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                    .foregroundStyle(iconTint(state))
                    .frame(width: compact ? 14 : 16)
                Text(label(state))
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
                    .foregroundStyle(hover && state.isFailed ? NotchTheme.danger : .white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showState { trailing(state) }
            }
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: compact ? 26 : 32)
            .background(RoundedRectangle(cornerRadius: compact ? 8 : 10)
                .fill(hover ? NotchTheme.surfaceStrong : NotchTheme.surface))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            if state.isRunning { Button("Stop") { module.stop(cmd) } }
            else { Button("Run") { module.run(cmd) } }
            Button("Show output") { module.showTerminal(cmd) }
            Button("Open log in Terminal") { module.openLog(cmd) }
            Button("Run in Terminal") { TerminalLauncher.run(command: cmd.command, in: cmd.expandedCwd) }
        }
    }

    private func tap(_ state: RunState) {
        switch state {
        case .running, .failed: module.showTerminal(cmd)
        default: module.run(cmd)
        }
    }

    private func label(_ state: RunState) -> String {
        if hover {
            if state.isRunning { return "Show output" }
            if case .failed(_, let msg, _) = state { return msg ?? "Failed \u{2014} show output" }
        }
        return cmd.name
    }

    private func iconTint(_ state: RunState) -> Color {
        switch state {
        case .running: return devCyan
        case .failed: return NotchTheme.danger
        default: return .white
        }
    }

    @ViewBuilder
    private func trailing(_ state: RunState) -> some View {
        switch state {
        case .running(_, let since):
            HStack(spacing: 4) {
                if hover { Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(NotchTheme.danger) }
                else {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                }
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(devClock(tl.date.timeIntervalSince(since)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(NotchTheme.secondaryText)
                }
            }
        case .succeeded(let d):
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(NotchTheme.success)
                if !compact { Text(devClock(d)).font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchTheme.tertiaryText) }
            }
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(NotchTheme.danger)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: - Expanded

struct DevtoolsExpandedView: View {
    let module: MetroModule
    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 6)]

    var body: some View {
        if let cmd = module.terminalCommand {
            TerminalOutputView(module: module, cmd: cmd)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(module.servers) { DevServerCard(module: module, server: $0, showOutput: $0.id == module.servers.first?.id) }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(module.taskCommands) { TaskButton(module: module, cmd: $0) }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct DevServerCard: View {
    let module: MetroModule
    let server: MetroModule.DevServer
    var showOutput = true

    var body: some View {
        let svc = server.service
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PulsingDot(color: module.statusColor(server), size: 7, isPulsing: svc.phase == .bundling)
                    .frame(width: 16, height: 16)
                DevServerSwitcher(module: module, server: server)
                Text(":" + String(svc.port)).font(NotchTheme.monoFont).foregroundStyle(NotchTheme.tertiaryText)
                Text(module.statusText(server)).font(NotchTheme.captionFont).foregroundStyle(module.statusColor(server)).lineLimit(1)
                if let p = svc.platform, svc.phase != .offline {
                    Text(p == "ios" ? "iOS" : p == "android" ? "Android" : p)
                        .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(NotchTheme.surface))
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    let reachable = module.isReachable(server)
                    DevIconButton(symbol: "arrow.clockwise", help: "Reload app", enabled: reachable) { module.reload(server) }
                    DevIconButton(symbol: "line.3.horizontal", help: "Dev menu", enabled: reachable) { module.openDevMenu(server) }
                    DevToolsControl(module: module, server: server)
                    StartStopButton(module: module, server: server)
                    if let c = server.command, module.runner.run(for: c.id) != nil {
                        DevIconButton(symbol: "terminal", help: "Show output") { module.showTerminal(c) }
                    } else if showOutput {
                        OutputMenu(module: module)
                    }
                }
                .fixedSize()
            }
            detail
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(NotchTheme.surface))
    }

    @ViewBuilder
    private var detail: some View {
        let svc = server.service
        if svc.phase == .bundling {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: svc.progress).progressViewStyle(.linear).tint(devCyan)
                Text(svc.totalFiles > 0 ? "\(svc.transformedFiles) / \(svc.totalFiles) files" : "Starting\u{2026}")
                    .font(NotchTheme.monoFont).foregroundStyle(NotchTheme.secondaryText)
            }
        } else if svc.phase == .failed, let msg = svc.errorMessage {
            Text(msg).font(.system(size: 11, design: .monospaced)).foregroundStyle(NotchTheme.danger)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } else if module.isExternal(server) {
            Text("Running outside NotchDeck \u{2014} reload and menu use the events socket")
                .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText).lineLimit(1)
        } else if let c = server.command, let run = module.runner.run(for: c.id), !run.tail.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(run.tail.suffix(2).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, design: .monospaced)).foregroundStyle(NotchTheme.tertiaryText).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let c = server.command {
            Text("Start runs `\(c.command)`").font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText).lineLimit(1)
        } else {
            Text("Watching :\(svc.port) \u{2014} add a Dev server command for this port to start it here")
                .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText).lineLimit(1)
        }
    }
}

// MARK: - Dashboard (270 x 200)

struct DevtoolsDashboardView: View {
    let module: MetroModule

    var body: some View {
        let summary = module.summaryServer
        let servers = module.servers
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PulsingDot(color: summary.map(module.statusColor) ?? NotchTheme.tertiaryText, size: 6,
                           isPulsing: summary?.service.phase == .bundling)
                    .frame(width: 14, height: 14)
                if servers.count <= 1, let s = summary, s.commands.count > 1 {
                    DevServerSwitcher(module: module, server: s, font: .system(size: 12, weight: .semibold))
                } else {
                    Text("Devtools").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                if let s = summary?.service, s.phase == .bundling {
                    ProgressRing(progress: s.progress, color: devCyan).frame(width: 12, height: 12)
                }
                if servers.count <= 1, let s = summary {
                    Text(module.statusText(s)).font(NotchTheme.captionFont).foregroundStyle(module.statusColor(s)).lineLimit(1)
                }
                if servers.count > 1 { OutputMenu(module: module) }
            }
            if servers.count <= 1, let s = summary {
                HStack(spacing: 6) {
                    controls(s, fill: true)
                    OutputMenu(module: module, fill: true)
                }
            } else {
                ForEach(servers) { s in
                    HStack(spacing: 5) {
                        Circle().fill(module.statusColor(s)).frame(width: 6, height: 6)
                        DevServerSwitcher(module: module, server: s, font: .system(size: 11, weight: .medium))
                        Text(":\(s.port)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(NotchTheme.tertiaryText)
                        Spacer(minLength: 0)
                        controls(s, fill: false).fixedSize()
                    }
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(module.taskCommands) { TaskButton(module: module, cmd: $0, compact: true) }
                }
            }
        }
        .padding(2)
        .frame(width: 270, height: 200, alignment: .topLeading)
    }

    @ViewBuilder
    private func controls(_ s: MetroModule.DevServer, fill: Bool) -> some View {
        let reachable = module.isReachable(s)
        DevIconButton(symbol: "arrow.clockwise", help: "Reload app", enabled: reachable, minWidth: fill ? 26 : 22) { module.reload(s) }
        DevIconButton(symbol: "line.3.horizontal", help: "Dev menu", enabled: reachable, minWidth: fill ? 26 : 22) { module.openDevMenu(s) }
        DevToolsControl(module: module, server: s, fill: fill)
        StartStopButton(module: module, server: s)
    }
}
