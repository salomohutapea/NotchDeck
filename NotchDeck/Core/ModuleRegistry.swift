import Foundation
import Observation

@MainActor @Observable
final class ModuleRegistry {
    static let shared = ModuleRegistry()

    @ObservationIgnored private let modules: [ModuleID: any NotchModule]
    @ObservationIgnored private var running: Set<ModuleID> = []
    @ObservationIgnored private let settings = AppSettings.shared

    private init() {
        modules = [
            .dashboard: DashboardModule(),
            .system: SystemModule(),
            .nowPlaying: NowPlayingModule(),
            .musicLyrics: MusicLyricsModule(),
            .aiStatus: AIStatusModule(),
            .metro: MetroModule(),
            .buildStatus: BuildStatusModule(),
            .fileShelf: FileShelfModule(),
            .clipboard: ClipboardModule(),
            .pomodoro: PomodoroModule(),
        ]
    }

    func module(for id: ModuleID) -> any NotchModule {
        // Dictionary is built from every ModuleID case in init.
        modules[id]!
    }

    /// Enabled modules in the user's tab order.
    var enabledModules: [any NotchModule] {
        settings.enabledModules.map { module(for: $0) }
    }

    /// Largest `preferredExpandedSize` of any module (sizes the panel).
    var maxPreferredSize: CGSize {
        var w = NotchMetrics.expandedContentSize.width, h = NotchMetrics.expandedContentSize.height
        for m in modules.values {
            w = max(w, m.preferredExpandedSize.width)
            h = max(h, m.preferredExpandedSize.height)
        }
        return CGSize(width: w, height: h)
    }

    func isEnabled(_ id: ModuleID) -> Bool { settings.enabledModules.contains(id) }

    /// Enabled + live modules, highest compactPriority first (stable w.r.t. tab order).
    var liveModules: [any NotchModule] {
        enabledModules.enumerated()
            .filter { $0.element.isLive }
            .sorted { a, b in
                if a.element.compactPriority != b.element.compactPriority {
                    return a.element.compactPriority > b.element.compactPriority
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Icons for the collapsed live notch, most important first (callers show the first 4).
    var compactItems: [CompactItem] {
        enabledModules.enumerated()
            .flatMap { offset, m in m.compactItems().map { ($0, offset, m.compactPriority) } }
            .sorted { a, b in
                if a.0.rank != b.0.rank { return a.0.rank < b.0.rank }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.1 < b.1
            }
            .map(\.0)
            .prefix(AppSettings.shared.maxCompactIcons).map { $0 }
    }

    var topLiveModule: (any NotchModule)? { liveModules.first }

    func setEnabled(_ id: ModuleID, _ enabled: Bool) {
        var list = settings.enabledModules
        if enabled {
            guard !list.contains(id) else { return }
            list.append(id)
        } else {
            list.removeAll { $0 == id }
        }
        settings.enabledModules = list
        sync()
    }

    /// Start enabled modules and keep running state in sync with settings from now on.
    func startEnabled() {
        sync()
        observeChanges({ _ = AppSettings.shared.enabledModules }, onChange: { [weak self] in self?.sync() })
    }

    func stopAll() {
        for id in running { module(for: id).stop() }
        running.removeAll()
    }

    private func sync() {
        let wanted = Set(settings.enabledModules)
        for id in ModuleID.allCases {
            if wanted.contains(id), !running.contains(id) {
                running.insert(id)
                module(for: id).start()
            } else if !wanted.contains(id), running.contains(id) {
                running.remove(id)
                module(for: id).stop()
            }
        }
    }
}
