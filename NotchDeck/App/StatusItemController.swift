import AppKit

/// Menu bar extra: Settings…, per-module toggles, Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    private var item: NSStatusItem?
    private let settings = AppSettings.shared

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "NotchDeck")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = settings.showMenuBarIcon
        self.item = item
        observeChanges({ _ = AppSettings.shared.showMenuBarIcon }, onChange: { [weak self] in
            self?.item?.isVisible = AppSettings.shared.showMenuBarIcon
        })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let live = NSMenuItem(title: "Collapsed Icons", action: #selector(toggleLive), keyEquivalent: "")
        live.target = self
        live.state = settings.showLiveActivities ? .on : .off
        menu.addItem(live)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for id in ModuleID.allCases {
            let mi = NSMenuItem(title: id.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id.rawValue
            mi.state = settings.enabledModules.contains(id) ? .on : .off
            mi.image = NSImage(systemSymbolName: id.systemImage, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchDeck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        ModuleRegistry.shared.setEnabled(id, !settings.enabledModules.contains(id))
    }

    @objc private func toggleLive() { settings.showLiveActivities.toggle() }

    @objc private func quit() { NSApp.terminate(nil) }
}
