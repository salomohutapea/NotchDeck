import SwiftUI
import Observation
import ServiceManagement

enum PeekStyle: String, CaseIterable, Identifiable {
    case compact, full, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Compact banner"
        case .full: return "Full panel"
        case .off: return "Don't open"
        }
    }
}

/// Resize animation flavour for the notch shape.
enum AnimationStyle: String, CaseIterable, Identifiable {
    case smooth, snappy, jelly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .snappy: return "Snappy"
        case .jelly: return "Jelly"
        }
    }
    var animation: Animation {
        switch self {
        case .smooth: return .spring(response: 0.38, dampingFraction: 0.8)
        case .snappy: return .spring(response: 0.27, dampingFraction: 0.92)
        case .jelly: return .spring(response: 0.44, dampingFraction: 0.66)
        }
    }
    /// Current style read straight from UserDefaults so non-isolated code (NotchTheme) can use it.
    static var current: AnimationStyle {
        UserDefaults.standard.string(forKey: "animationStyle").flatMap(AnimationStyle.init(rawValue:)) ?? .jelly
    }
}

/// Which displays get a notch panel.
enum DisplayMode: Equatable {
    case notchedOnly
    case mainScreen
    case allScreens
    /// A particular display; matched by display ID first, then by name (IDs can change across reboots).
    case specific(id: UInt32, name: String)

    var storageValue: String {
        switch self {
        case .notchedOnly: return "notchedOnly"
        case .mainScreen: return "mainScreen"
        case .allScreens: return "allScreens"
        case .specific(let id, let name): return "specific:\(id):\(name)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "notchedOnly": self = .notchedOnly
        case "mainScreen": self = .mainScreen
        case "allScreens": self = .allScreens
        default:
            let parts = storageValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "specific", let id = UInt32(parts[1]) else { return nil }
            self = .specific(id: id, name: String(parts[2]))
        }
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    var enabledModules: [ModuleID] {
        didSet { defaults.set(enabledModules.map(\.rawValue), forKey: "enabledModules") }
    }
    /// Enabled modules that do not get their own tab (they keep running; Home may show them).
    var hiddenTabs: Set<ModuleID> {
        didSet { defaults.set(hiddenTabs.map(\.rawValue).sorted(), forKey: "hiddenTabs") }
    }
    /// Home panes.
    var dashboardShowMusic: Bool { didSet { defaults.set(dashboardShowMusic, forKey: "dashboard.showMusic") } }
    var dashboardShowDevtools: Bool { didSet { defaults.set(dashboardShowDevtools, forKey: "dashboard.showDevtools") } }
    var dashboardShowAI: Bool { didSet { defaults.set(dashboardShowAI, forKey: "dashboard.showAI") } }
    var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: "expandOnHover") } }
    var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    var collapseDelay: Double { didSet { defaults.set(collapseDelay, forKey: "collapseDelay") } }
    /// Icons shown beside the notch when collapsed (0-4); fewer keeps menu bar items visible.
    var maxCompactIcons: Int { didSet { defaults.set(min(max(maxCompactIcons, 0), 4), forKey: "maxCompactIcons") } }
    var showLiveActivities: Bool { didSet { defaults.set(showLiveActivities, forKey: "showLiveActivities") } }
    var peekStyle: PeekStyle { didSet { defaults.set(peekStyle.rawValue, forKey: "peekStyle") } }
    /// Kept for existing callers: true unless peeking is switched off.
    var peekOnEvents: Bool {
        get { peekStyle != .off }
        set { peekStyle = newValue ? (peekStyle == .off ? .compact : peekStyle) : .off }
    }
    /// Scroll / swipe gestures on the notch (swipe up closes, sideways switches tabs, swipe down opens).
    var gesturesEnabled: Bool { didSet { defaults.set(gesturesEnabled, forKey: "gesturesEnabled") } }
    var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: "animationStyle") } }
    var displayMode: DisplayMode { didSet { defaults.set(displayMode.storageValue, forKey: "displayMode") } }
    /// Extra width (pt) added to the collapsed shape on notched displays.
    static let extraWidthRange: ClosedRange<Double> = -30...60
    /// Extra height (pt) added to the collapsed shape on notched displays.
    static let extraHeightRange: ClosedRange<Double> = 0...12
    var notchExtraWidth: Double {
        didSet {
            let c = min(max(notchExtraWidth, Self.extraWidthRange.lowerBound), Self.extraWidthRange.upperBound)
            if c != notchExtraWidth { notchExtraWidth = c; return }
            defaults.set(notchExtraWidth, forKey: "notchExtraWidth")
        }
    }
    var notchExtraHeight: Double {
        didSet {
            let c = min(max(notchExtraHeight, Self.extraHeightRange.lowerBound), Self.extraHeightRange.upperBound)
            if c != notchExtraHeight { notchExtraHeight = c; return }
            defaults.set(notchExtraHeight, forKey: "notchExtraHeight")
        }
    }
    /// Hide the notch panels while the frontmost app is in a fullscreen Space on that display.
    var hideInFullscreen: Bool { didSet { defaults.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isSyncingLogin = false

    private init() {
        let d = UserDefaults.standard
        var enabled: [ModuleID]
        if let raw = d.array(forKey: "enabledModules") as? [String] {
            // Modules added in later versions are enabled once, appended to the user's order.
            let known = Set((d.array(forKey: "knownModules") as? [String]) ?? ModuleID.legacyCases.map(\.rawValue))
            let added = ModuleID.allCases.filter { !known.contains($0.rawValue) }
            enabled = raw.compactMap(ModuleID.init(rawValue:)) + added
            // didSet doesn't run in init, and knownModules is updated below, so persist now or they're lost.
            if !added.isEmpty { d.set(enabled.map(\.rawValue), forKey: "enabledModules") }
        } else {
            enabled = ModuleID.allCases
        }
        // One-time Home migration (also applies to new users): Home first, the modules it
        // embeds stay enabled but lose their own tab.
        var hidden: Set<ModuleID>
        if d.bool(forKey: "dashboardMigrated") {
            hidden = Set(((d.array(forKey: "hiddenTabs") as? [String]) ?? []).compactMap(ModuleID.init(rawValue:)))
        } else {
            enabled.removeAll { $0 == .dashboard }
            enabled.insert(.dashboard, at: 0)
            hidden = [.nowPlaying, .musicLyrics, .metro, .aiStatus]
            d.set(enabled.map(\.rawValue), forKey: "enabledModules")
            d.set(hidden.map(\.rawValue).sorted(), forKey: "hiddenTabs")
            d.set(true, forKey: "dashboardMigrated")
        }
        enabledModules = enabled
        hiddenTabs = hidden
        dashboardShowMusic = d.object(forKey: "dashboard.showMusic") as? Bool ?? true
        dashboardShowDevtools = d.object(forKey: "dashboard.showDevtools") as? Bool ?? true
        dashboardShowAI = d.object(forKey: "dashboard.showAI") as? Bool ?? true
        d.set(ModuleID.allCases.map(\.rawValue), forKey: "knownModules")
        expandOnHover = d.object(forKey: "expandOnHover") as? Bool ?? true
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0.15
        collapseDelay = d.object(forKey: "collapseDelay") as? Double ?? 0.35
        maxCompactIcons = min(max(d.object(forKey: "maxCompactIcons") as? Int ?? 4, 0), 4)
        showLiveActivities = d.object(forKey: "showLiveActivities") as? Bool ?? true
        if let raw = d.string(forKey: "peekStyle"), let style = PeekStyle(rawValue: raw) {
            peekStyle = style
        } else {
            let legacy = d.object(forKey: "peekOnEvents") as? Bool ?? true
            peekStyle = legacy ? .compact : .off
        }
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        gesturesEnabled = d.object(forKey: "gesturesEnabled") as? Bool ?? true
        animationStyle = AnimationStyle.current
        displayMode = d.string(forKey: "displayMode").flatMap(DisplayMode.init(storageValue:)) ?? .notchedOnly
        let w = d.object(forKey: "notchExtraWidth") as? Double ?? 0
        notchExtraWidth = min(max(w, Self.extraWidthRange.lowerBound), Self.extraWidthRange.upperBound)
        let h = d.object(forKey: "notchExtraHeight") as? Double ?? 0
        notchExtraHeight = min(max(h, Self.extraHeightRange.lowerBound), Self.extraHeightRange.upperBound)
        hideInFullscreen = d.object(forKey: "hideInFullscreen") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("NotchDeck: launch at login failed: \(error.localizedDescription)")
        }
        // Reflect the real system state (registration can fail or need approval).
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin {
            isSyncingLogin = true
            launchAtLogin = actual
            isSyncingLogin = false
        }
    }
}
