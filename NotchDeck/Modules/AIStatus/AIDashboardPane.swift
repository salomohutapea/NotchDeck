import SwiftUI

/// 196 x 210 Home pane: compact list of agent sessions.
struct AIDashboardPane: View {
    let module: AIStatusModule

    var body: some View {
        let rows = module.orderedSessions
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.secondaryText)
                Text("AI Agents").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(NotchTheme.surfaceStrong))
                }
            }
            if rows.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(NotchTheme.tertiaryText)
                    Text(module.hasReceivedEvents ? "All agents idle" : "No agent activity")
                        .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.secondaryText)
                    Text(module.hasReceivedEvents
                         ? "Start Claude Code or Codex."
                         : "Install hooks in Settings \u{2192} AI Agents.")
                        .font(.system(size: 10)).foregroundStyle(NotchTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    ForEach(rows.prefix(4)) { Row(session: $0) }
                }
                if rows.count > 4 {
                    Text("+\(rows.count - 4) more").font(.system(size: 10)).foregroundStyle(NotchTheme.tertiaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .foregroundStyle(NotchTheme.primaryText)
    }

    private struct Row: View {
        let session: AISession

        var body: some View {
            HStack(spacing: 7) {
                AgentGlyph(agent: session.agent, working: session.state.isWorking, size: 13)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    chip
                }
                Spacer(minLength: 2)
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    if let e = session.elapsed(at: tl.date) {
                        Text(formatElapsed(e)).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(NotchTheme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(NotchTheme.surface))
            .opacity(session.state == .idle ? 0.55 : 1)
        }

        private var chip: some View {
            let (text, color): (String, Color) = {
                switch session.state {
                case .thinking: return ("Thinking", session.agent.color)
                case .tool(let n): return (n, session.agent.color)
                case .waitingForUser: return ("Needs input", NotchTheme.warning)
                case .done: return ("Done", NotchTheme.success)
                case .idle: return ("Idle", NotchTheme.tertiaryText)
                }
            }()
            return Text(text).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.18)))
        }
    }
}
