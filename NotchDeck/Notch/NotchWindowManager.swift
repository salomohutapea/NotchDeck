import AppKit
import SwiftUI

/// Owns one NotchPanel per target screen (see `DisplayMode`), rebuilds them when the screen
/// configuration or the display setting changes, drives pointer tracking and scroll gestures, and
/// hides the panels while a fullscreen app owns the display.
@MainActor
final class NotchWindowManager {
    static let shared = NotchWindowManager()

    private struct Entry {
        let panel: NotchPanel
        let context: NotchScreenContext
    }

    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var signature: [String] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var extraMonitors: [Any] = []
    private var dragStartChangeCount = NSPasteboard(name: .drag).changeCount
    private var started = false
    private let gestures = NotchGestureHandler()
    private var hiddenDisplays: Set<CGDirectDisplayID> = []

    func start() {
        guard !started else { return }
        started = true
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDragged { self?.checkDrag() }
                self?.pointerMoved()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDragged { self?.checkDrag() }
                self?.pointerMoved()
            }
            return event
        }
        installAuxiliaryMonitors()
        installScrollMonitors()
        installFullscreenObservers()
        observeChanges({ _ = AppSettings.shared.displayMode }, onChange: { [weak self] in self?.rebuild() })
        observeChanges({ _ = AppSettings.shared.hideInFullscreen },
                       onChange: { [weak self] in self?.updateFullscreenVisibility() })
        observeChanges({
            let c = NotchCoordinator.shared
            _ = c.state; _ = c.activeDisplay; _ = c.selectedModule
        }, onChange: { [weak self] in self?.syncKeyState() })
    }

    // MARK: Click-outside, Escape, drag lifecycle

    private func installAuxiliaryMonitors() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragStartChangeCount = NSPasteboard(name: .drag).changeCount
                self?.collapseIfClickedOutside()
            }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        let localUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseUp() }
            return event
        }
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
        extraMonitors = [down, up, localUp, localDown, keys].compactMap { $0 }
    }

    private func isNotchOpen() -> Bool { NotchCoordinator.shared.state != .collapsed }

    private func collapseIfClickedOutside() {
        let c = NotchCoordinator.shared
        guard isNotchOpen(), !c.isDragActive, let id = c.activeDisplay, let entry = entries[id] else { return }
        if !entry.context.hitRect().contains(NSEvent.mouseLocation) { c.collapse() }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, isNotchOpen(),
              event.window is NotchPanel else { return false }
        NotchCoordinator.shared.collapse()
        return true
    }

    private func mouseUp() {
        dragStartChangeCount = NSPasteboard(name: .drag).changeCount
        let c = NotchCoordinator.shared
        guard c.isDragActive else { return }
        // Give the drop handler time to run before resuming normal collapse behaviour.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NotchCoordinator.shared.dragEnded()
        }
    }

    /// A drag session is in flight when the drag pasteboard changed since mouse-down and has content.
    private func checkDrag() {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragStartChangeCount, !(pb.types ?? []).isEmpty else { return }
        let location = NSEvent.mouseLocation
        for (id, entry) in entries where entry.context.dragRect().contains(location) {
            NotchCoordinator.shared.dragEntered(display: id)
            return
        }
    }

    /// The panel can take key focus only while the notch is open.
    private func syncKeyState() {
        let c = NotchCoordinator.shared
        for (id, entry) in entries {
            let open = c.state != .collapsed && c.activeDisplay == id
            entry.panel.allowsKey = open
            if open, c.wantsKey, !entry.panel.isKeyWindow {
                c.wantsKey = false
                entry.panel.makeKey()
            } else if !open, entry.panel.isKeyWindow {
                entry.panel.resignKey()
            }
        }
    }

    // MARK: Screens

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// Screens that get a panel for the current display mode. The first one is the primary target (peeks).
    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        let notched = all.filter(NotchMetrics.hasNotch)
        func notchedOrMain() -> [NSScreen] {
            if !notched.isEmpty { return notched }
            return all.first.map { [$0] } ?? []
        }
        switch AppSettings.shared.displayMode {
        case .notchedOnly:
            return notchedOrMain()
        case .mainScreen:
            return all.first.map { [$0] } ?? []
        case .allScreens:
            // Notched displays first so they receive peeks.
            return notched + all.filter { !NotchMetrics.hasNotch($0) }
        case .specific(let id, let name):
            if let match = all.first(where: { displayID(of: $0) == id })
                ?? all.first(where: { $0.localizedName == name }) {
                return [match]
            }
            return notchedOrMain()
        }
    }

    private func rebuild() {
        let screens = targetScreens()
        let newSignature = [AppSettings.shared.displayMode.storageValue] + screens.map { s -> String in
            let size = NotchMetrics.notchSize(for: s)
            return "\(displayID(of: s) ?? 0)|\(s.frame)|\(size)|\(NotchMetrics.notchCenterX(for: s))"
        }
        guard newSignature != signature else { return }
        signature = newSignature

        NotchCoordinator.shared.reset()
        for entry in entries.values { entry.panel.orderOut(nil); entry.panel.close() }
        entries.removeAll()
        hiddenDisplays.removeAll()

        NotchMetrics.updateTerminalSize(for: screens)
        let maxContent = ModuleRegistry.shared.maxPreferredSize
        let content = CGSize(width: max(maxContent.width, NotchMetrics.terminalContentSize.width),
                             height: max(maxContent.height, NotchMetrics.terminalContentSize.height))
        for screen in screens {
            guard let id = displayID(of: screen) else { continue }
            let context = NotchScreenContext(screen: screen, displayID: id)
            let size = NotchMetrics.panelSize(notchHeight: context.baseSize.height, content: content)
            let frame = NSRect(x: context.centerX - size.width / 2,
                               y: screen.frame.maxY - size.height,
                               width: size.width, height: size.height)
            let panel = NotchPanel(frame: frame)
            let host = FirstMouseHostingView(rootView: NotchRootView(context: context))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            entries[id] = Entry(panel: panel, context: context)
        }
        NotchCoordinator.shared.primaryDisplayID = screens.first.flatMap(displayID(of:))
        updateFullscreenVisibility()
        pointerMoved()
        startDebugSnapshots()
    }

    // MARK: Scroll gestures

    private func installScrollMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleScroll(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }
        extraMonitors.append(contentsOf: [global, local].compactMap { $0 })
    }

    /// Routes a scroll event to the gesture handler when the pointer is inside a visible notch's hit rect.
    private func handleScroll(_ event: NSEvent) -> Bool {
        let location = NSEvent.mouseLocation
        for (id, entry) in entries where !hiddenDisplays.contains(id) {
            if entry.context.hitRect().contains(location) {
                return gestures.handle(event, context: entry.context, panel: entry.panel)
            }
        }
        gestures.reset()
        return false
    }

    // MARK: Fullscreen hiding

    private func installFullscreenObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullscreenCheck() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFullscreenCheck() }
        }
    }

    /// Space / activation changes land before the menu bar and window lists settle: check now and again shortly after.
    private func scheduleFullscreenCheck() {
        updateFullscreenVisibility()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.updateFullscreenVisibility()
            try? await Task.sleep(for: .milliseconds(900))
            self?.updateFullscreenVisibility()
        }
    }

    /// True when the frontmost app is showing a fullscreen Space on the display: the menu bar is
    /// hidden (`visibleFrame` reaches `frame`'s top edge) and one of the app's windows covers the screen.
    /// The window check avoids hiding the notch when the user merely auto-hides the menu bar.
    private func isFullscreenSpaceActive(on id: CGDirectDisplayID) -> Bool {
        guard let screen = screen(for: id) else { return false }
        guard screen.visibleFrame.maxY >= screen.frame.maxY - 0.5 else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return false }
        let display = CGDisplayBounds(id)
        let slack = screen.safeAreaInsets.top + 1 // fullscreen content may sit below the notch
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if rect.width >= display.width - 1, rect.height >= display.height - slack,
               rect.midX > display.minX, rect.midX < display.maxX { return true }
        }
        return false
    }

    private func updateFullscreenVisibility() {
        let enabled = AppSettings.shared.hideInFullscreen
        for (id, entry) in entries {
            let shouldHide = enabled && isFullscreenSpaceActive(on: id)
            if shouldHide, !hiddenDisplays.contains(id) {
                hiddenDisplays.insert(id)
                if NotchCoordinator.shared.activeDisplay == id { NotchCoordinator.shared.collapse() }
                entry.panel.ignoresMouseEvents = true
                entry.panel.alphaValue = 0
                entry.panel.orderOut(nil)
                NotchCoordinator.shared.pointerChanged(inside: false, display: id)
            } else if !shouldHide, hiddenDisplays.contains(id) {
                hiddenDisplays.remove(id)
                entry.panel.alphaValue = 1
                entry.panel.orderFrontRegardless()
            }
        }
        pointerMoved()
    }

    // MARK: Debug snapshots (visual QA without Screen Recording permission)

    private var snapshotTimer: Timer?

    /// With `NOTCHDECK_SNAPSHOT_DIR` set, renders each panel's content to `<dir>/notch-<display>.png` every 1.5s.
    private func startDebugSnapshots() {
        #if DEBUG
        guard snapshotTimer == nil, let dir = ProcessInfo.processInfo.environment["NOTCHDECK_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? ModuleRegistry.shared.compactItems.map { "\($0.rank) \($0.id)" }.joined(separator: "\n")
                    .write(toFile: "\(dir)/items.txt", atomically: true, encoding: .utf8)
                for (id, entry) in self.entries {
                    guard let view = entry.panel.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/notch-\(id).png"))
                }
            }
        }
        #endif
    }

    // MARK: Pointer tracking

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        for (id, entry) in entries {
            if hiddenDisplays.contains(id) { continue }
            let inside = entry.context.hitRect().contains(location)
                || (NotchCoordinator.shared.isDragActive && entry.context.dragRect().contains(location))
            if entry.panel.ignoresMouseEvents == inside {
                entry.panel.ignoresMouseEvents = !inside
            }
            NotchCoordinator.shared.pointerChanged(inside: inside, display: id)
        }
    }
}
