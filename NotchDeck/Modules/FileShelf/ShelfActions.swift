import AppKit
import SwiftUI
import QuickLookThumbnailing
import QuickLookUI

@MainActor
enum ShelfActions {
    static func copy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        }
    }

    static func quickLook(_ url: URL) {
        let store = ShelfStore.shared
        let urls = store.items.map(\.url)
        QuickLookController.shared.show(urls: urls, index: urls.firstIndex(of: url) ?? 0)
    }

    static func sizeString(_ url: URL) -> String {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return "" }
        if v.isDirectory == true { return "Folder" }
        guard let size = v.fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Thumbnails

@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for url: URL) async -> NSImage? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mod)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                               scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Quick Look

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func show(urls: [URL], index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        panel.reloadData()
        panel.currentPreviewItemIndex = min(index, urls.count - 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { index < urls.count ? urls[index] as NSURL : nil }
    }
}

// MARK: - Drag-all handle (AppKit multi-item drag source)

struct ShelfDragAllHandle: View {
    var body: some View {
        let store = ShelfStore.shared
        ZStack {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 10))
                Text(store.selection.isEmpty ? "Drag all" : "Drag \(store.selection.count)")
                    .font(NotchTheme.captionFont)
            }
            .foregroundStyle(NotchTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            DragAllSource().opacity(0.011)
        }
        .help("Drag all (or selected) items out")
    }
}

private struct DragAllSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAllNSView { DragAllNSView() }
    func updateNSView(_ nsView: DragAllNSView, context: Context) {}
}

final class DragAllNSView: NSView, NSDraggingSource {
    private var started = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { started = false }

    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        let items: [ShelfItem] = MainActor.assumeIsolated { ShelfStore.shared.selectedOrAll }
        guard !items.isEmpty else { return }
        let drags = items.prefix(20).enumerated().map { (i, item) -> NSDraggingItem in
            let d = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            let origin = convert(event.locationInWindow, from: nil)
            d.setDraggingFrame(NSRect(x: origin.x - 16 + CGFloat(i) * 3, y: origin.y - 16 - CGFloat(i) * 3,
                                      width: 32, height: 32), contents: icon)
            return d
        }
        draggedIDs = Set(items.map(\.id))
        beginDraggingSession(with: drags, event: event, source: self)
    }

    private var draggedIDs: Set<UUID> = []

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let ids = draggedIDs
        guard !operation.isEmpty, !ids.isEmpty else { return }
        MainActor.assumeIsolated {
            guard ShelfStore.removeAfterDrag else { return }
            ShelfStore.shared.remove(ids, deleteFiles: false)
        }
    }
}
