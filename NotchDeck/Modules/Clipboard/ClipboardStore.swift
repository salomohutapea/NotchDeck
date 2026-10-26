import AppKit
import Observation
import CryptoKit

enum ClipKind: String, Codable { case text, url, file, image, color }

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var smart: ClipSmart = .plain
    /// text / URL / newline-joined file paths / hex colour. nil for images.
    var text: String?
    var imageFile: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var imageHash: String?
    var date = Date()
    var pinned = false
    var sourceBundleID: String?
    var sourceName: String?
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All", pinned = "Pinned", text = "Text", images = "Images", links = "Links", code = "Code"
    var id: String { rawValue }

    func matches(_ i: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return i.pinned
        case .images: return i.kind == .image
        case .links: return i.smart == .url || i.smart == .deeplink || i.kind == .url
        case .code: return [.json, .jwt, .code, .stackTrace].contains(i.smart)
        case .text: return i.kind != .image && ![.json, .jwt, .code, .stackTrace, .url, .deeplink].contains(i.smart) && i.kind != .url
        }
    }
}

enum ClipPrefs {
    static let defaultExcluded = ["com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
                                  "com.agilebits.onepassword4", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords"]
    static var maxItems: Int {
        let v = UserDefaults.standard.integer(forKey: "clipboard.maxItems")
        return v > 0 ? v : 200
    }
    static var remember: Bool { UserDefaults.standard.object(forKey: "clipboard.remember") as? Bool ?? true }
    static var hotkeyEnabled: Bool { UserDefaults.standard.object(forKey: "clipboard.hotkey") as? Bool ?? true }
    static var excluded: [String] {
        get { UserDefaults.standard.stringArray(forKey: "clipboard.excludedApps") ?? defaultExcluded }
        set { UserDefaults.standard.set(newValue, forKey: "clipboard.excludedApps") }
    }
}

@MainActor @Observable
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    @ObservationIgnored var ownChangeCount = -1
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let thumbs = NSCache<NSString, NSImage>()
    @ObservationIgnored private let fullImages = NSCache<NSString, NSImage>()

    static let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchDeck", isDirectory: true)
    static var jsonURL: URL { dir.appendingPathComponent("clipboard.json") }
    static var imagesDir: URL { dir.appendingPathComponent("clipboard-images", isDirectory: true) }

    func load() {
        try? FileManager.default.createDirectory(at: Self.imagesDir, withIntermediateDirectories: true)
        guard ClipPrefs.remember else { wipeDisk(); return }
        guard let data = try? Data(contentsOf: Self.jsonURL),
              let loaded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = loaded.filter { i in
            i.kind != .image || (i.imageFile.map { FileManager.default.fileExists(atPath: Self.imagesDir.appendingPathComponent($0).path) } ?? false)
        }
        prune()
        cleanOrphanImages()
    }

    // MARK: Mutations

    func addText(_ text: String, kind: ClipKind, smart: ClipSmart, app: NSRunningApplication?) {
        if let idx = items.firstIndex(where: { $0.kind == kind && $0.text == text }) {
            var it = items.remove(at: idx)
            it.date = Date()
            items.insert(it, at: 0)
        } else {
            items.insert(ClipItem(kind: kind, smart: smart, text: text, sourceBundleID: app?.bundleIdentifier, sourceName: app?.localizedName), at: 0)
        }
        prune(); scheduleSave()
    }

    func addImage(png: Data, width: Int, height: Int, hash: String, app: NSRunningApplication?) {
        if let idx = items.firstIndex(where: { $0.imageHash == hash }) {
            var it = items.remove(at: idx)
            it.date = Date()
            items.insert(it, at: 0)
        } else {
            let name = UUID().uuidString + ".png"
            try? FileManager.default.createDirectory(at: Self.imagesDir, withIntermediateDirectories: true)
            guard (try? png.write(to: Self.imagesDir.appendingPathComponent(name))) != nil else { return }
            items.insert(ClipItem(kind: .image, text: nil, imageFile: name, imageWidth: width, imageHeight: height, imageHash: hash,
                                  sourceBundleID: app?.bundleIdentifier, sourceName: app?.localizedName), at: 0)
        }
        prune(); scheduleSave()
    }

    func bump(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: idx)
        it.date = Date()
        items.insert(it, at: 0)
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        prune(); scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(items[idx])
        items.remove(at: idx)
        scheduleSave()
    }

    func clear() {
        items.removeAll()
        thumbs.removeAllObjects(); fullImages.removeAllObjects()
        wipeDisk()
    }

    /// Evict oldest unpinned items beyond the cap. Pinned items never count against eviction.
    func prune() {
        let cap = ClipPrefs.maxItems
        var unpinned = items.filter { !$0.pinned }.count
        guard unpinned > cap else { return }
        var i = items.count - 1
        while unpinned > cap, i >= 0 {
            if !items[i].pinned { removeFiles(items[i]); items.remove(at: i); unpinned -= 1 }
            i -= 1
        }
    }

    // MARK: Images

    func fullImage(_ it: ClipItem) -> NSImage? {
        guard let f = it.imageFile else { return nil }
        if let c = fullImages.object(forKey: f as NSString) { return c }
        guard let img = NSImage(contentsOf: Self.imagesDir.appendingPathComponent(f)) else { return nil }
        fullImages.setObject(img, forKey: f as NSString)
        return img
    }

    func thumbnail(_ it: ClipItem) -> NSImage? {
        guard let f = it.imageFile else { return nil }
        if let c = thumbs.object(forKey: f as NSString) { return c }
        let url = Self.imagesDir.appendingPathComponent(f) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs.setObject(img, forKey: f as NSString)
        return img
    }

    nonisolated static func encodePNG(fromTIFF tiff: Data) -> (png: Data, w: Int, h: Int, hash: String)? {
        guard let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { return nil }
        var maxSide: CGFloat = 2048
        var width = CGFloat(cg.width), height = CGFloat(cg.height)
        for _ in 0..<8 {
            let scale = min(1, maxSide / max(width, height))
            let w = max(1, Int(width * scale)), h = max(1, Int(height * scale))
            let image: CGImage
            if scale < 1 {
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let scaled = ctx.makeImage() else { return nil }
                image = scaled
            } else { image = cg }
            let out = NSBitmapImageRep(cgImage: image)
            if let png = out.representation(using: .png, properties: [:]), png.count <= 1_000_000 {
                let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                return (png, image.width, image.height, hash)
            }
            maxSide = maxSide * 0.75
            width = CGFloat(cg.width); height = CGFloat(cg.height)
        }
        return nil
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard ClipPrefs.remember else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.jsonURL, options: .atomic) }
    }

    private func removeFiles(_ it: ClipItem) {
        guard let f = it.imageFile else { return }
        try? FileManager.default.removeItem(at: Self.imagesDir.appendingPathComponent(f))
        thumbs.removeObject(forKey: f as NSString); fullImages.removeObject(forKey: f as NSString)
    }

    private func wipeDisk() {
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.jsonURL)
        try? FileManager.default.removeItem(at: Self.imagesDir)
    }

    private func cleanOrphanImages() {
        let keep = Set(items.compactMap(\.imageFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.imagesDir.path)) ?? []
        for f in files where !keep.contains(f) { try? FileManager.default.removeItem(at: Self.imagesDir.appendingPathComponent(f)) }
    }
}
