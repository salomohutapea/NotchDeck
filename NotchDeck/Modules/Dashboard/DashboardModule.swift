import SwiftUI
import Observation

/// "Home": Music & Lyrics, Devtools and AI Agents side by side. Never peeks or goes live itself;
/// each embedded module keeps its own compact banner.
@MainActor @Observable
final class DashboardModule: NotchModule {
    let id: ModuleID = .dashboard
    var isLive = false
    var compactPriority = 0

    init() {}

    /// Sum of the visible panes plus gaps (800 x 210 with all three).
    var preferredExpandedSize: CGSize {
        if Self.activeTerminal != nil { return NotchMetrics.terminalContentSize }
        let panes = DashboardPane.visible(AppSettings.shared)
        guard !panes.isEmpty else { return CGSize(width: 320, height: 120) }
        let w = panes.reduce(0) { $0 + $1.width } + DashboardPane.gap * CGFloat(panes.count - 1)
        return CGSize(width: w, height: DashboardPane.height)
    }

    /// Devtools command whose output currently takes over the whole Home layout.
    @MainActor static var activeTerminal: (module: MetroModule, cmd: DevCommand)? {
        let registry = ModuleRegistry.shared
        guard registry.isEnabled(.metro), let m = registry.module(for: .metro) as? MetroModule,
              let cmd = m.terminalCommand else { return nil }
        return (m, cmd)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expanded() -> AnyView { AnyView(DashboardView()) }
    func settings() -> AnyView? { AnyView(DashboardSettings()) }
    func start() {}
    func stop() {}
}

enum DashboardPane: CaseIterable {
    case music, devtools, ai

    static let gap: CGFloat = 12
    static let height: CGFloat = 210

    var width: CGFloat {
        switch self {
        case .music: return 310
        case .devtools: return 270
        case .ai: return 196
        }
    }
    var module: ModuleID {
        switch self {
        case .music: return .musicLyrics
        case .devtools: return .metro
        case .ai: return .aiStatus
        }
    }

    @MainActor static func visible(_ s: AppSettings) -> [DashboardPane] {
        allCases.filter {
            switch $0 {
            case .music: return s.dashboardShowMusic
            case .devtools: return s.dashboardShowDevtools
            case .ai: return s.dashboardShowAI
            }
        }
    }
}

private struct DashboardView: View {
    private let settings = AppSettings.shared

    var body: some View {
        let panes = DashboardPane.visible(settings)
        if let t = DashboardModule.activeTerminal {
            TerminalOutputView(module: t.module, cmd: t.cmd)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if panes.isEmpty {
            Text("Enable a pane in Settings \u{2192} Modules \u{2192} Home")
                .font(NotchTheme.bodyFont).foregroundStyle(NotchTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: DashboardPane.gap) {
                ForEach(panes, id: \.module) { pane in
                    PaneCard(pane: pane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct PaneCard: View {
    let pane: DashboardPane
    private let registry = ModuleRegistry.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            if registry.isEnabled(pane.module), let section = registry.module(for: pane.module).dashboardSection() {
                section
            } else {
                VStack(spacing: 6) {
                    Image(systemName: pane.module.systemImage).font(.system(size: 18))
                        .foregroundStyle(NotchTheme.tertiaryText)
                    Text(registry.isEnabled(pane.module) ? "Not available" : "\(pane.module.title) is off")
                        .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText)
                }
            }
        }
        .frame(width: pane.width, height: DashboardPane.height)
        .background(shape.fill(Color.white.opacity(0.05)))
        .clipShape(shape)
    }
}

private struct DashboardSettings: View {
    @Bindable private var settings = AppSettings.shared
    var body: some View {
        Toggle("Music & Lyrics pane", isOn: $settings.dashboardShowMusic)
        Toggle("Devtools pane", isOn: $settings.dashboardShowDevtools)
        Toggle("AI Agents pane", isOn: $settings.dashboardShowAI)
        Text("Panes show their module live; the module keeps running (and peeking) even without its own tab.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
