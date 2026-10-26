import Foundation
import Observation
import CoreGraphics
import SwiftUI

enum NotchState: Equatable, Hashable {
    case collapsed
    case peeking(ModuleID)
    case expanded
}

@MainActor @Observable
final class NotchCoordinator {
    static let shared = NotchCoordinator()

    private(set) var state: NotchState = .collapsed
    var selectedModule: ModuleID?
    /// Display on which the notch is currently open (expanded / peeking). nil while collapsed.
    private(set) var activeDisplay: CGDirectDisplayID?
    /// Display that receives peeks. Set by the window manager.
    @ObservationIgnored var primaryDisplayID: CGDirectDisplayID?
    /// True while a drag session (files / images / text) is in progress near the notch.
    /// The notch will not auto-collapse while this is set. Modules may read it.
    private(set) var isDragActive = false
    /// Bumped on every peek; the compact banner keys its content on it to crossfade.
    private(set) var peekToken = 0
    /// Set by `open(_:)`; the window manager makes the panel key (for text input) once.
    @ObservationIgnored var wantsKey = false
    @ObservationIgnored private var dragOpened = false
    /// True while the Devtools terminal has keyboard focus: the notch stays open when the pointer leaves.
    @ObservationIgnored private(set) var keyboardHold = false

    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var pointerInside: Set<CGDirectDisplayID> = []

    private let settings = AppSettings.shared
    private let registry = ModuleRegistry.shared

    @ObservationIgnored private var lastUserChoice: (id: ModuleID, at: Date)?

    private init() {}

    // MARK: Tabs

    /// Enabled modules minus those without a tab, plus the selected one when it is a temporary tab.
    var tabIDs: [ModuleID] {
        var ids = settings.enabledModules.filter { !settings.hiddenTabs.contains($0) }
        if let s = selectedModule, settings.enabledModules.contains(s), !ids.contains(s) { ids.append(s) }
        return ids
    }

    /// True when Home (enabled) shows `id` in one of its panes.
    func isHostedInHome(_ id: ModuleID) -> Bool {
        guard settings.enabledModules.contains(.dashboard) else { return false }
        switch id {
        case .musicLyrics, .nowPlaying: return settings.dashboardShowMusic
        case .metro: return settings.dashboardShowDevtools
        case .aiStatus: return settings.dashboardShowAI
        default: return false
        }
    }

    /// The tab that should show `id`: itself when it has a tab, Home when Home hosts it, else itself (temporary tab).
    func resolveTab(_ id: ModuleID) -> ModuleID {
        if settings.enabledModules.contains(id), !settings.hiddenTabs.contains(id) { return id }
        if isHostedInHome(id) { return .dashboard }
        return id
    }

    /// Module whose content is on screen while expanded.
    var shownModuleID: ModuleID? {
        if let s = selectedModule, settings.enabledModules.contains(s) { return s }
        return tabIDs.first ?? settings.enabledModules.first
    }

    private func defaultTab() -> ModuleID? {
        if let c = lastUserChoice, Date().timeIntervalSince(c.at) < 60, settings.enabledModules.contains(c.id) { return c.id }
        let home = ModuleID.dashboard
        if settings.enabledModules.contains(home), !settings.hiddenTabs.contains(home) { return home }
        if let top = registry.topLiveModule?.id { return resolveTab(top) }
        return settings.enabledModules.first { !settings.hiddenTabs.contains($0) } ?? settings.enabledModules.first
    }

    // MARK: Public API

    /// Peeks with controls (volume / brightness slider): hovering keeps the banner instead of expanding.
    @ObservationIgnored private var peekHoldsOnHover = false
    @ObservationIgnored private var peekDuration: TimeInterval = 4

    func peek(_ id: ModuleID, duration: TimeInterval = 4, holdOnHover: Bool = false) {
        guard id != .dashboard, settings.peekOnEvents, settings.enabledModules.contains(id),
              let display = primaryDisplayID else { return }
        if state == .expanded { return }
        var duration = duration
        if settings.peekStyle == .compact {
            duration = min(duration, id == .nowPlaying ? 3 : 5)
        }
        collapseTask?.cancel()
        selectedModule = resolveTab(id)
        activeDisplay = display
        // Swapping while a peek is showing just changes the content (no collapse/re-expand).
        withAnimation(.easeInOut(duration: 0.18)) { peekToken &+= 1 }
        if state != .peeking(id) { state = .peeking(id) }
        peekHoldsOnHover = holdOnHover
        peekDuration = duration
        if holdOnHover, pointerInside.contains(display) { peekTask?.cancel(); return }
        schedulePeekEnd(after: duration)
    }

    private func schedulePeekEnd(after duration: TimeInterval) {
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            if case .peeking = self.state { self.collapse() }
        }
    }

    func expand(on display: CGDirectDisplayID) {
        hoverTask?.cancel()
        collapseTask?.cancel()
        peekTask?.cancel()
        if case .peeking = state {
            // keep the peeked tab
        } else if state == .collapsed {
            selectedModule = defaultTab()
        }
        activeDisplay = display
        state = .expanded
    }

    func collapse() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        peekTask?.cancel()
        peekHoldsOnHover = false
        keyboardHold = false
        state = .collapsed
        activeDisplay = nil
        wantsKey = false
    }

    func select(_ id: ModuleID) {
        selectedModule = id
        lastUserChoice = (id, Date())
    }

    /// Switch to the neighbouring tab (`delta` = +1 next, -1 previous). Clamped, no wrap-around.
    @discardableResult
    func selectAdjacent(_ delta: Int) -> Bool {
        let ids = tabIDs
        guard let current = shownModuleID, let index = ids.firstIndex(of: current) else { return false }
        let target = index + delta
        guard ids.indices.contains(target) else { return false }
        select(ids[target])
        return true
    }

    /// Open the notch on the primary display with `id` selected (hotkeys, menu items).
    /// Toggles closed if that module is already showing.
    func open(_ id: ModuleID) {
        guard settings.enabledModules.contains(id), let display = primaryDisplayID else { return }
        let tab = resolveTab(id)
        if state == .expanded, selectedModule == tab { collapse(); return }
        selectedModule = tab
        wantsKey = true
        expand(on: display)
    }

    // MARK: Drag support

    /// A drag with pasteboard content is hovering near the notch: open on the shelf.
    func dragEntered(display: CGDirectDisplayID) {
        isDragActive = true
        collapseTask?.cancel()
        guard !dragOpened else { return }
        dragOpened = true
        guard settings.enabledModules.contains(.fileShelf) else { return }
        expand(on: display)
        selectedModule = .fileShelf
    }

    /// Mouse released (drop finished or cancelled): resume normal collapse behaviour.
    func dragEnded() {
        guard isDragActive || dragOpened else { return }
        isDragActive = false
        dragOpened = false
        guard state == .expanded, let display = activeDisplay, !pointerInside.contains(display) else { return }
        let delay = settings.collapseDelay + 0.4
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isDragActive,
                  !self.pointerInside.contains(display) else { return }
            self.collapse()
        }
    }

    /// Called by the window manager whenever the pointer enters / leaves a display's notch rect.
    func pointerChanged(inside: Bool, display: CGDirectDisplayID) {
        let was = pointerInside.contains(display)
        guard was != inside else { return }
        if inside { pointerInside.insert(display) } else { pointerInside.remove(display) }

        if case .peeking = state, peekHoldsOnHover, activeDisplay == display {
            // Interactive banner: stay as a banner while hovered, finish shortly after leaving.
            hoverTask?.cancel()
            if inside { peekTask?.cancel() } else { schedulePeekEnd(after: min(peekDuration, 1.5)) }
            return
        }

        if inside {
            collapseTask?.cancel()
            guard settings.expandOnHover else { return }
            let canExpand: Bool
            switch state {
            case .collapsed: canExpand = true
            case .peeking: canExpand = activeDisplay == display
            case .expanded: canExpand = false
            }
            guard canExpand else { return }
            hoverTask?.cancel()
            let delay = settings.hoverDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.pointerInside.contains(display) else { return }
                self.expand(on: display)
            }
        } else {
            hoverTask?.cancel()
            guard state == .expanded, activeDisplay == display, !isDragActive, !keyboardHold else { return }
            let delay = settings.collapseDelay
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, !self.isDragActive, !self.keyboardHold,
                      !self.pointerInside.contains(display) else { return }
                self.collapse()
            }
        }
    }

    func setKeyboardHold(_ on: Bool) {
        guard keyboardHold != on else { return }
        keyboardHold = on
        if on { collapseTask?.cancel(); return }
        // Focus moved elsewhere: collapse as if the pointer had just left.
        guard state == .expanded, let display = activeDisplay, !pointerInside.contains(display) else { return }
        let delay = settings.collapseDelay
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.keyboardHold, !self.pointerInside.contains(display) else { return }
            self.collapse()
        }
    }

    /// Forget pointer bookkeeping (screen layout changed).
    func reset() {
        pointerInside.removeAll()
        collapse()
    }
}
