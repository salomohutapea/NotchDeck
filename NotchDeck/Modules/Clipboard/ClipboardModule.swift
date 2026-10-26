import SwiftUI
import AppKit
import Observation

@MainActor @Observable
final class ClipboardModule: NotchModule {
    let id: ModuleID = .clipboard
    var isLive = false
    var compactPriority = 5

    let store = ClipboardStore()
    var query = ""
    var filter: ClipFilter = .all
    var selectedID: UUID?
    var hoveredID: UUID?
    /// Item whose "Copied" flash is showing.
    var flashID: UUID?

    @ObservationIgnored private var monitor: ClipboardMonitor?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var hotkeyObserver: NSObjectProtocol?

    init() {}

    var visibleItems: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.items.filter { i in
            guard filter.matches(i) else { return false }
            guard !q.isEmpty else { return true }
            return (i.text?.lowercased().contains(q) ?? false) || (i.sourceName?.lowercased().contains(q) ?? false)
                || i.smart.badge.lowercased() == q || (i.kind == .image && "image".contains(q))
        }
        // pinned first, then recency (store order is already recency)
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    // MARK: Copy back

    func copy(_ item: ClipItem) {
        write(item, text: nil)
        store.bump(item.id)
        flash(item.id)
    }

    /// Copy a derived string (pretty JSON, JWT payload, decoded base64).
    func copyDerived(_ s: String, for item: ClipItem) {
        write(item, text: s)
        flash(item.id)
    }

    private func write(_ item: ClipItem, text override: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let s = override {
            pb.setString(s, forType: .string)
        } else {
            switch item.kind {
            case .text, .url, .color: pb.setString(item.text ?? "", forType: .string)
            case .file:
                let urls = (item.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
                if !urls.isEmpty { pb.writeObjects(urls) } else { pb.setString(item.text ?? "", forType: .string) }
            case .image:
                if let img = store.fullImage(item) { pb.writeObjects([img]) }
            }
        }
        store.ownChangeCount = pb.changeCount
        selectedID = item.id
    }

    private func flash(_ id: UUID) {
        flashID = id
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.flashID = nil
        }
    }

    // MARK: NotchModule

    func compactLeading() -> AnyView {
        AnyView(Image(systemName: "doc.on.clipboard.fill").font(.system(size: 13)).foregroundStyle(NotchTheme.secondaryText))
    }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expanded() -> AnyView { AnyView(ClipboardExpandedView(module: self)) }
    func settings() -> AnyView? { AnyView(ClipboardSettingsView(module: self)) }

    func start() {
        if !loaded { store.load(); loaded = true }
        if monitor == nil { monitor = ClipboardMonitor(store: store) }
        monitor?.start()
        applyHotkey()
        hotkeyObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotkey() }
        }
    }

    private func applyHotkey() {
        if ClipPrefs.hotkeyEnabled {
            HotkeyCenter.shared.register(id: "clipboard.open", keyCode: 9, modifiers: [.command, .control]) {
                NotchCoordinator.shared.open(.clipboard)
            }
        } else {
            HotkeyCenter.shared.unregister(id: "clipboard.open")
        }
    }

    func stop() {
        monitor?.stop()
        store.saveNow()
        if let o = hotkeyObserver { NotificationCenter.default.removeObserver(o); hotkeyObserver = nil }
        HotkeyCenter.shared.unregister(id: "clipboard.open")
    }
}
