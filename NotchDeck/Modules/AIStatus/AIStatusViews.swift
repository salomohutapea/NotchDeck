import SwiftUI

// MARK: - Compact

struct AICompactLeading: View {
    let module: AIStatusModule

    var body: some View {
        if let s = module.topSession {
            HStack(spacing: 4) {
                AgentGlyph(agent: s.agent, working: s.state.isWorking, size: 15)
                if module.extraActiveCount > 0 {
                    Text("+\(module.extraActiveCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(NotchTheme.surfaceStrong))
                        .foregroundStyle(NotchTheme.primaryText)
                }
            }
        } else {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(NotchTheme.secondaryText)
        }
    }
}

struct AICompactTrailing: View {
    let module: AIStatusModule

    var body: some View {
        if let s = module.topSession {
            switch s.state {
            case .thinking:
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    label(formatElapsed(s.elapsed(at: tl.date) ?? 0), NotchTheme.primaryText, mono: true)
                }
            case .tool(let name): label(name, s.agent.color)
            case .waitingForUser: label("Input?", NotchTheme.warning)
            case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(NotchTheme.success)
            case .idle: label("Idle", NotchTheme.tertiaryText)
            }
        } else {
            EmptyView()
        }
    }

    private func label(_ t: String, _ c: Color, mono: Bool = false) -> some View {
        Text(t)
            .font(mono ? NotchTheme.monoFont : .system(size: 11, weight: .semibold))
            .foregroundStyle(c)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 62, alignment: .trailing)
    }
}

struct AgentGlyph: View {
    let agent: AIAgent
    var working: Bool
    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !working)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Image(agent.logoAsset)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(agent.color)
                .opacity(working ? 0.65 + 0.35 * (0.5 + 0.5 * sin(t * 4)) : 0.9)
                .scaleEffect(working ? 1 + 0.08 * sin(t * 4) : 1)
        }
    }
}

// MARK: - Expanded

struct AIExpandedView: View {
    let module: AIStatusModule

    var body: some View {
        let rows = module.orderedSessions
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(rows) { SessionRow(session: $0) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(NotchTheme.tertiaryText)
            Text(module.hasReceivedEvents ? "All agents are idle" : "No agent activity yet")
                .font(NotchTheme.titleFont).foregroundStyle(NotchTheme.primaryText)
            Text(module.hasReceivedEvents
                 ? "Start Claude Code or Codex to see live status here."
                 : "Install hooks for Claude Code and Codex in Settings → AI Agents.")
                .font(NotchTheme.bodyFont).foregroundStyle(NotchTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

private struct SessionRow: View {
    let session: AISession

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(agent: session.agent, working: session.state.isWorking, size: 17)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotchTheme.primaryText).lineLimit(1)
                    statusChip
                }
                Text(subtitle).font(NotchTheme.captionFont)
                    .foregroundStyle(NotchTheme.secondaryText).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                if let e = session.elapsed(at: tl.date) {
                    Text(formatElapsed(e)).font(NotchTheme.monoFont).foregroundStyle(NotchTheme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(NotchTheme.surface))
        .opacity(session.state == .idle ? 0.55 : 1)
    }

    private var subtitle: String {
        if case .waitingForUser(let m) = session.state, let m, !m.isEmpty { return m }
        return session.prompt ?? session.agent.displayName
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            switch session.state {
            case .thinking: return ("Thinking", session.agent.color)
            case .tool(let n): return (n, session.agent.color)
            case .waitingForUser: return ("Needs input", NotchTheme.warning)
            case .done: return ("Done", NotchTheme.success)
            case .idle: return ("Idle", NotchTheme.tertiaryText)
            }
        }()
        return Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

// MARK: - Settings

struct AISettingsView: View {
    let module: AIStatusModule
    @State private var portText = ""

    var body: some View {
        Group {
            HStack {
                Text("Hook server port")
                Spacer()
                TextField("47474", text: $portText)
                    .frame(width: 70).multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyPort)
                Button("Apply", action: applyPort)
                    .disabled(Int(portText) == nil || portText == String(module.port))
            }
            HStack(spacing: 6) {
                Text("Server")
                Spacer()
                switch module.serverStatus {
                case .listening(let p):
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Listening on 127.0.0.1:\(String(p))").foregroundStyle(.secondary)
                case .error(let m):
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(m).foregroundStyle(.red)
                case .stopped:
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    Text("Stopped").foregroundStyle(.secondary)
                }
            }
            installRow(.claude, installed: module.claudeInstalled)
            installRow(.codex, installed: module.codexInstalled)
            HStack {
                Button("Send test event") { module.sendTestEvent() }
                Spacer()
                if let m = module.installMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Hooks are added to ~/.claude/settings.json and ~/.codex/hooks.json (a timestamped backup is made first). Codex will NOT run new hooks until you review and trust them: open a Codex session, type /hooks, and approve the NotchDeck entries (then start a new session). Hooks are read when a session starts, so restart running sessions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            portText = String(module.port)
            module.refreshInstallStatus()
        }
    }

    private func applyPort() {
        guard let p = Int(portText), (1024...65535).contains(p) else {
            module.installMessage = "Port must be between 1024 and 65535."
            return
        }
        UserDefaults.standard.set(p, forKey: "aiStatus.port")
        module.restartServer()
        module.installMessage = "Note: hook scripts use NOTCHDECK_PORT (default 47474)."
        if p == 47474 { module.installMessage = nil }
    }

    private func installRow(_ t: HookInstaller.Target, installed: Bool) -> some View {
        HStack {
            Text(t.displayName)
            Spacer()
            Text(installed ? "Installed" : "Not installed")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            if installed {
                Button("Uninstall") { module.uninstall(t) }
                Button("Reinstall") { module.install(t) }
            } else {
                Button("Install") { module.install(t) }
            }
        }
    }
}

// MARK: - Compact peek row

struct AIPeekRow: View {
    let session: AISession

    var body: some View {
        let name = session.agent == .claude ? "Claude" : "Codex"
        let text: String = {
            if case .waitingForUser = session.state { return "\(name) needs input" }
            return "\(name) finished"
        }()
        HStack(spacing: 8) {
            AgentGlyph(agent: session.agent, working: false, size: 14)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryText)
                .lineLimit(1)
                .fixedSize()
            Text(session.project)
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.secondaryText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Collapsed-notch icon for one agent; a yellow dot means it is waiting for you.
struct AIAgentCompactIcon: View {
    let agent: AIAgent
    let working: Bool
    let waiting: Bool

    var body: some View {
        AgentGlyph(agent: agent, working: working, size: 17)
            .frame(width: CompactItem.iconSize, height: CompactItem.iconSize)
            .overlay(alignment: .topTrailing) {
                if waiting { Circle().fill(NotchTheme.warning).frame(width: 6, height: 6) }
            }
    }
}
