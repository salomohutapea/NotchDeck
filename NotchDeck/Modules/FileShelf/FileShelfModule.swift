import SwiftUI
import Observation

@MainActor @Observable
final class FileShelfModule: NotchModule {
    let id: ModuleID = .fileShelf
    /// Never widens the collapsed notch.
    let isLive = false
    var compactPriority = 10

    @ObservationIgnored private let store = ShelfStore.shared

    init() {}

    func start() { store.loadIfNeeded() }
    func stop() {}

    func compactLeading() -> AnyView {
        AnyView(Image(systemName: "tray.full.fill").font(.system(size: 13)).foregroundStyle(NotchTheme.secondaryText))
    }

    func compactTrailing() -> AnyView {
        AnyView(CountBadge())
    }

    func expanded() -> AnyView { AnyView(ShelfExpandedView()) }
    func settings() -> AnyView? { AnyView(ShelfSettings()) }
}

private struct CountBadge: View {
    var body: some View {
        let n = ShelfStore.shared.items.count
        if n > 0 {
            Text("\(n)").font(NotchTheme.monoFont).foregroundStyle(NotchTheme.primaryText)
        }
    }
}

// MARK: - Settings

private struct ShelfSettings: View {
    @AppStorage("fileShelf.removeAfterDrag") private var removeAfterDrag = true
    @AppStorage("fileShelf.keepBetweenLaunches") private var keep = true
    var body: some View {
        Toggle("Remove from shelf after dragging out", isOn: $removeAfterDrag)
        Toggle("Keep shelf between launches", isOn: $keep)
        Button("Open shelf folder") {
            try? FileManager.default.createDirectory(at: ShelfStore.shelfDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(ShelfStore.shelfDir)
        }
    }
}

// MARK: - Expanded

private struct ShelfExpandedView: View {
    @State private var targeted = false

    var body: some View {
        let store = ShelfStore.shared
        ZStack {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30, weight: .light))
                    Text("Drag files here").font(NotchTheme.bodyFont)
                }
                .foregroundStyle(NotchTheme.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ShelfHeader()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(store.items) { item in
                                ShelfTile(item: item)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            if targeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(NotchTheme.accent.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(NotchTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    )
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .semibold))
                            Text("Drop to add to shelf").font(NotchTheme.titleFont)
                        }
                        .foregroundStyle(NotchTheme.primaryText)
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $targeted) { providers in
            ShelfStore.shared.ingest(providers)
        }
    }
}

private struct ShelfHeader: View {
    var body: some View {
        let store = ShelfStore.shared
        HStack(spacing: 10) {
            Text(store.selection.isEmpty ? "\(store.items.count) item\(store.items.count == 1 ? "" : "s")"
                                         : "\(store.selection.count) selected")
                .font(NotchTheme.captionFont)
                .foregroundStyle(NotchTheme.secondaryText)
            if let notice = store.lastNotice {
                Text(notice).font(NotchTheme.captionFont).foregroundStyle(NotchTheme.warning)
            }
            Spacer()
            ShelfDragAllHandle()
                .frame(width: 84, height: 20)
            headerButton("airplayaudio", "AirDrop all") { ShelfActions.airDrop(store.selectedOrAll.map(\.url)) }
            headerButton("trash", "Clear shelf") { store.clear() }
        }
        .frame(height: 22)
    }

    private func headerButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.secondaryText)
                .frame(width: 22, height: 20)
                .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Tile

private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        let store = ShelfStore.shared
        let selected = store.selection.contains(item.id)
        VStack(spacing: 3) {
            ZStack(alignment: .top) {
                ShelfThumbnail(url: item.url)
                    .frame(width: 64, height: 64)
                if hovering {
                    HStack {
                        tileButton("eye.fill") { ShelfActions.quickLook(item.url) }
                        Spacer()
                        tileButton("xmark") { store.remove([item.id]) }
                    }
                    .padding(2)
                }
            }
            .frame(width: 72, height: 72)
            .background(selected ? NotchTheme.accent.opacity(0.28) : NotchTheme.surface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? NotchTheme.accent : .clear, lineWidth: 1.5)
            )
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.primaryText)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 76)
            Text(ShelfActions.sizeString(item.url))
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.tertiaryText)
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture().modifiers(.command).onEnded {
            if store.selection.contains(item.id) { store.selection.remove(item.id) }
            else { store.selection.insert(item.id) }
        })
        .onTapGesture(count: 2) { ShelfActions.quickLook(item.url) }
        .onTapGesture { store.selection = selected && store.selection.count == 1 ? [] : [item.id] }
        .onDrag {
            ShelfStore.shared.trackDragOut(ids: [item.id])
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu { ShelfItemMenu(item: item) }
    }

    private func tileButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.black.opacity(0.7), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShelfItemMenu: View {
    let item: ShelfItem
    var body: some View {
        let store = ShelfStore.shared
        let targets = store.selection.contains(item.id) ? store.items(for: store.selection) : [item]
        let urls = targets.map(\.url)
        Button("Quick Look") { ShelfActions.quickLook(item.url) }
        Button("Open") { NSWorkspace.shared.open(item.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        Button("Copy") { ShelfActions.copy(urls) }
        Button("AirDrop") { ShelfActions.airDrop(urls) }
        Menu("Share") {
            ForEach(Array(NSSharingService.sharingServices(forItems: urls).enumerated()), id: \.offset) { _, service in
                Button {
                    service.perform(withItems: urls)
                } label: {
                    Label { Text(service.title) } icon: { Image(nsImage: service.image) }
                }
            }
        }
        Divider()
        Button("Remove from Shelf") { store.remove(Set(targets.map(\.id))) }
    }
}

// MARK: - Thumbnails

private struct ShelfThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url.path) { image = await ThumbnailCache.thumbnail(for: url) }
    }
}
