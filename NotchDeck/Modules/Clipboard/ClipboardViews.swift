import SwiftUI
import AppKit

private func smartColor(_ s: ClipSmart) -> Color {
    switch s {
    case .json: return Color(red: 1.0, green: 0.78, blue: 0.3)
    case .jwt: return Color(red: 0.85, green: 0.45, blue: 1.0)
    case .url, .deeplink: return NotchTheme.accent
    case .hexColor: return Color(red: 1.0, green: 0.5, blue: 0.6)
    case .base64: return Color(red: 0.4, green: 0.85, blue: 0.85)
    case .uuid: return Color(red: 0.6, green: 0.7, blue: 1.0)
    case .path: return NotchTheme.success
    case .stackTrace: return NotchTheme.danger
    case .code: return Color(red: 1.0, green: 0.62, blue: 0.35)
    case .plain: return NotchTheme.secondaryText
    }
}

private func hexSwatch(_ text: String?) -> Color? {
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), let c = ClipDetect.hexColor(t) else { return nil }
    return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
}

@MainActor private let iconCache = NSCache<NSString, NSImage>()
@MainActor private func appIcon(_ bundleID: String?) -> NSImage? {
    guard let b = bundleID else { return nil }
    if let c = iconCache.object(forKey: b as NSString) { return c }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
    let img = NSWorkspace.shared.icon(forFile: url.path)
    img.size = NSSize(width: 16, height: 16)
    iconCache.setObject(img, forKey: b as NSString)
    return img
}

private func oneLine(_ it: ClipItem) -> String {
    switch it.kind {
    case .image: return "Image \(it.imageWidth)×\(it.imageHeight)"
    case .file: return (it.text ?? "").split(separator: "\n").map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    default:
        let t = it.text ?? ""
        if it.smart == .url || it.smart == .deeplink { return ClipDetect.urlSummary(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let collapsed = t.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(160))
    }
}

// MARK: - Expanded

struct ClipboardExpandedView: View {
    let module: ClipboardModule
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var m = module
        let items = module.visibleItems
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(NotchTheme.tertiaryText)
                    TextField("Search", text: $m.query)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchTheme.primaryText)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 7).frame(width: 118, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(NotchTheme.surface))
                ForEach(ClipFilter.allCases) { f in
                    Button { module.filter = f } label: {
                        Text(f.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(Capsule().fill(module.filter == f ? NotchTheme.surfaceStrong : Color.clear))
                            .foregroundStyle(module.filter == f ? NotchTheme.primaryText : NotchTheme.secondaryText)
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                if items.isEmpty {
                    Text(module.store.items.isEmpty ? "Copy something to see it here" : "No matches")
                        .font(NotchTheme.bodyFont).foregroundStyle(NotchTheme.tertiaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(items) { it in ClipRow(module: module, item: it) }
                        }
                    }
                }
                let shown = items.first(where: { $0.id == (module.hoveredID ?? module.selectedID) })
                if let shown {
                    ClipDetailPane(module: module, item: shown)
                        .frame(width: 168)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ClipRow: View {
    let module: ClipboardModule
    let item: ClipItem
    @State private var hover = false

    var body: some View {
        let flashing = module.flashID == item.id
        HStack(spacing: 6) {
            badge.frame(width: 38)
            Text(flashing ? "Copied" : oneLine(item))
                .font(item.smart == .plain || item.smart == .url || item.kind == .image ? .system(size: 11.5) : .system(size: 11, design: .monospaced))
                .foregroundStyle(flashing ? NotchTheme.success : NotchTheme.primaryText)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover { actions } else {
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(NotchTheme.warning) }
                if let icon = appIcon(item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(relative(item.date)).font(.system(size: 9.5)).foregroundStyle(NotchTheme.tertiaryText)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover || module.selectedID == item.id ? NotchTheme.surface : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { module.copy(item) }
        .onHover { h in
            hover = h
            if h { module.hoveredID = item.id } else if module.hoveredID == item.id { module.hoveredID = nil }
        }
    }

    @ViewBuilder private var badge: some View {
        if item.kind == .image, let t = module.store.thumbnail(item) {
            Image(nsImage: t).resizable().scaledToFill().frame(width: 22, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let c = hexSwatch(item.text), item.smart == .hexColor {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 22, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        } else if item.kind == .file {
            Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(NotchTheme.success)
        } else if item.kind == .image {
            Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(NotchTheme.secondaryText)
        } else {
            Text(item.smart.badge)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(smartColor(item.smart))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(smartColor(item.smart).opacity(0.16)))
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            switch item.smart {
            case .json:
                if let t = item.text, let p = ClipDetect.prettyJSON(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    ClipAction(icon: "curlybraces", help: "Copy pretty") { module.copyDerived(p, for: item) }
                }
            case .jwt:
                if let t = item.text, let j = ClipDetect.jwt(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    ClipAction(icon: "key.horizontal", help: "Copy payload") { module.copyDerived(j.payload, for: item) }
                }
            case .base64:
                if let t = item.text, let d = ClipDetect.decodeBase64(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    ClipAction(icon: "text.badge.checkmark", help: "Copy decoded") { module.copyDerived(d, for: item) }
                }
            default: EmptyView()
            }
            ClipAction(icon: item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin") { module.store.togglePin(item.id) }
            ClipAction(icon: "trash", help: "Delete") { module.store.delete(item.id) }
        }
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

struct ClipAction: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(NotchTheme.secondaryText).frame(width: 18, height: 18)
        }.buttonStyle(.plain).help(help)
    }
}

// MARK: - Detail pane

struct ClipDetailPane: View {
    let module: ClipboardModule
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(item.smart.badge).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(smartColor(item.smart))
                if let n = item.sourceName { Text(n).font(.system(size: 9)).foregroundStyle(NotchTheme.tertiaryText).lineLimit(1) }
                Spacer(minLength: 0)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(NotchTheme.surface))
    }

    @ViewBuilder private var content: some View {
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .image:
            if let img = module.store.fullImage(item) {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 100)
                Text("\(item.imageWidth) × \(item.imageHeight)").font(.system(size: 9)).foregroundStyle(NotchTheme.tertiaryText)
            }
        default:
            switch item.smart {
            case .json:
                mono(ClipDetect.prettyJSON(text) ?? text)
            case .jwt:
                if let j = ClipDetect.jwt(text) {
                    if let e = j.expiryText {
                        Text(e).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle((j.expiry ?? .distantFuture) > Date() ? NotchTheme.success : NotchTheme.danger)
                    }
                    mono(j.header + "\n" + j.payload)
                } else { mono(text) }
            case .base64:
                mono(ClipDetect.decodeBase64(text) ?? text)
            case .hexColor:
                if let c = hexSwatch(text) {
                    RoundedRectangle(cornerRadius: 6).fill(c).frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                mono(text)
            case .url, .deeplink:
                Text(ClipDetect.urlSummary(text)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(NotchTheme.accent).lineLimit(2)
                mono(text)
            case .plain: Text(String(text.prefix(700))).font(.system(size: 10.5)).foregroundStyle(NotchTheme.primaryText.opacity(0.9))
            default: mono(text)
            }
        }
    }

    private func mono(_ s: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(String(s.prefix(1500)))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(NotchTheme.primaryText.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
        }
    }
}

// MARK: - Settings

struct ClipboardSettingsView: View {
    let module: ClipboardModule
    @AppStorage("clipboard.maxItems") private var maxItems = 200
    @AppStorage("clipboard.remember") private var remember = true
    @AppStorage("clipboard.hotkey") private var hotkey = true
    @State private var excluded = ClipPrefs.excluded
    @State private var confirmClear = false

    var body: some View {
        Section("Clipboard") {
            Stepper("History size: \(maxItems)", value: $maxItems, in: 20...1000, step: 20)
                .onChange(of: maxItems) { _, _ in module.store.prune() }
            Toggle("Remember history between launches", isOn: $remember)
                .onChange(of: remember) { _, on in if on { module.store.saveNow() } else { module.store.clear() } }
            Toggle("Open with \u{2303}\u{2318}V", isOn: $hotkey)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignore copies from these apps").font(.caption).foregroundStyle(.secondary)
                ForEach(excluded, id: \.self) { b in
                    HStack {
                        Text(name(for: b)).font(.callout)
                        Spacer()
                        Button { excluded.removeAll { $0 == b }; ClipPrefs.excluded = excluded } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            }
            Text("Clipboard data never leaves this Mac. Items marked concealed/transient by password managers are always skipped.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history", role: .destructive) { confirmClear = true }
                .confirmationDialog("Delete all clipboard history, including pinned items?", isPresented: $confirmClear) {
                    Button("Clear history", role: .destructive) { module.store.clear() }
                }
        }
    }

    private func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            if let b = Bundle(url: u)?.bundleIdentifier, !excluded.contains(b) { excluded.append(b) }
        }
        ClipPrefs.excluded = excluded
    }
}
