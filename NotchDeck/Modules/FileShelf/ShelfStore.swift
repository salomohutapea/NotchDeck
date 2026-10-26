import AppKit
import Observation
import UniformTypeIdentifiers

/// One file on the shelf. Everything on the shelf is a real file on disk
/// (dropped images/text/URLs are materialised into the shelf folder).
struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var addedAt = Date()
    /// True when NotchDeck created the file itself (png/txt/webloc in the shelf folder).
    var owned = false

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore()
    static let maxItems = 50

    private(set) var items: [ShelfItem] = []
    var selection: Set<UUID> = []
    var lastNotice: String?

    nonisolated static let baseDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchDeck", isDirectory: true)
    }()
    nonisolated static let shelfDir = baseDir.appendingPathComponent("Shelf", isDirectory: true)
    static let indexURL = baseDir.appendingPathComponent("shelf.json")

    static var keepBetweenLaunches: Bool {
        UserDefaults.standard.object(forKey: "fileShelf.keepBetweenLaunches") as? Bool ?? true
    }
    static var removeAfterDrag: Bool {
        UserDefaults.standard.object(forKey: "fileShelf.removeAfterDrag") as? Bool ?? true
    }

    @ObservationIgnored private var loaded = false

    private init() { loadIfNeeded() }

    // MARK: Persistence

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: Self.shelfDir, withIntermediateDirectories: true)
        guard Self.keepBetweenLaunches else {
            // Fresh shelf each launch: drop the index and files we created.
            try? FileManager.default.removeItem(at: Self.indexURL)
            if let files = try? FileManager.default.contentsOfDirectory(at: Self.shelfDir, includingPropertiesForKeys: nil) {
                for f in files { try? FileManager.default.removeItem(at: f) }
            }
            return
        }
        guard let data = try? Data(contentsOf: Self.indexURL),
              let stored = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = stored.compactMap(Self.resolve)
        if items.count != stored.count { save() }
    }

    /// Resolve an item to an existing file, following the bookmark if it moved.
    static func resolve(_ item: ShelfItem) -> ShelfItem? {
        var item = item
        if FileManager.default.fileExists(atPath: item.path) { return item }
        guard let bm = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        item.path = url.path
        if stale, let fresh = try? url.bookmarkData() { item.bookmark = fresh }
        return item
    }

    private func save() {
        guard Self.keepBetweenLaunches else { return }
        try? FileManager.default.createDirectory(at: Self.baseDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    // MARK: Mutation

    @discardableResult
    func add(fileURL url: URL, owned: Bool = false) -> Bool {
        let url = url.standardizedFileURL
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        if let existing = items.first(where: { $0.path == url.path }) {
            selection = [existing.id]
            return true
        }
        guard items.count < Self.maxItems else {
            lastNotice = "Shelf is full (\(Self.maxItems) items)"
            return false
        }
        let item = ShelfItem(path: url.path, bookmark: try? url.bookmarkData(), owned: owned)
        items.insert(item, at: 0)
        save()
        return true
    }

    func remove(_ ids: Set<UUID>, deleteFiles: Bool = true) {
        for item in items where deleteFiles && ids.contains(item.id) && item.owned {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    func items(for ids: Set<UUID>) -> [ShelfItem] { items.filter { ids.contains($0.id) } }

    /// Selected items, or everything when nothing is selected.
    var selectedOrAll: [ShelfItem] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }

    // MARK: Drop ingestion

    /// Accepts providers from a SwiftUI drop. Returns true if any provider looks usable.
    func ingest(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(fileURL: url) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = Self.writeImage(data) else { return }
                    Task { @MainActor in self.add(fileURL: url, owned: true) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    guard let file = Self.writeWebloc(url) else { return }
                    Task { @MainActor in self.add(fileURL: file, owned: true) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let text = obj as? String, let url = Self.writeText(text) else { return }
                    Task { @MainActor in self.add(fileURL: url, owned: true) }
                }
            }
        }
        return accepted
    }

    // MARK: File writers (thread-safe, no actor state)

    nonisolated static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    nonisolated static func uniqueURL(base: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        var url = shelfDir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = shelfDir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    nonisolated static func writeImage(_ data: Data) -> URL? {
        var png = data
        if let rep = NSBitmapImageRep(data: data), let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        }
        let url = uniqueURL(base: "Image \(stamp())", ext: "png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    nonisolated static func writeText(_ text: String) -> URL? {
        let url = uniqueURL(base: "Text \(stamp())", ext: "txt")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    nonisolated static func writeWebloc(_ link: URL) -> URL? {
        let title = (link.host ?? "Link").replacingOccurrences(of: "/", with: "-")
        let url = uniqueURL(base: title, ext: "webloc")
        let plist: [String: Any] = ["URL": link.absoluteString]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: Drag-out tracking

    /// Called when a drag out of the shelf starts. SwiftUI's onDrag has no completion
    /// callback, so wait for the mouse button to be released and, if the pointer ended
    /// up outside our own windows, treat it as delivered.
    func trackDragOut(ids: Set<UUID>) {
        guard Self.removeAfterDrag else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(80))
            }
            let p = NSEvent.mouseLocation
            let inside = NSApp.windows.contains { $0.isVisible && $0.frame.contains(p) }
            guard !inside else { return }
            try? await Task.sleep(for: .milliseconds(400))
            self.remove(ids, deleteFiles: false)
        }
    }
}
