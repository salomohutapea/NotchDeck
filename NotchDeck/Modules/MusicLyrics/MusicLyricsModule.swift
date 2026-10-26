import SwiftUI
import Combine
import Observation

@MainActor @Observable
final class MusicLyricsModule: NotchModule {
    let id: ModuleID = .musicLyrics
    private(set) var isLive = false
    var compactPriority = 40
    let store = LyricsStore()

    @ObservationIgnored private let media = MediaService.shared
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0

    init() {}

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        media.acquire()
        sync()
        arm(generation)
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        media.release()
        isLive = false
        store.load(for: nil)
    }

    private func arm(_ gen: Int) {
        withObservationTracking {
            _ = media.track?.key
            _ = media.isPlaying
            _ = AppSettings.shared.enabledModules
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == gen else { return }
                self.sync()
                self.arm(gen)
            }
        }
    }

    private func sync() {
        // NowPlaying owns the collapsed slot unless it is disabled.
        let nowPlayingOn = AppSettings.shared.enabledModules.contains(.nowPlaying)
        let live = !nowPlayingOn && media.track != nil && media.isPlaying
        if isLive != live { isLive = live }
        store.load(for: media.track)
    }

    func compactLeading() -> AnyView { AnyView(LyricsCompactLeading()) }
    func compactTrailing() -> AnyView {
        AnyView(Image(systemName: "quote.bubble.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MediaService.shared.artworkTint))
    }
    func expanded() -> AnyView { AnyView(LyricsExpandedView(store: store)) }
    func settings() -> AnyView? { AnyView(LyricsSettings()) }
    func dashboardSection() -> AnyView? { AnyView(LyricsDashboardPane(store: store)) }
}

/// Size parameters so the same synced / plain lyrics views serve the full tab and the Home pane.
struct LyricsStyle {
    var fontSize: CGFloat
    var spacing: CGFloat
    var endPad: CGFloat
    var messageIcon: CGFloat
    var messageFont: Font
    static let full = LyricsStyle(fontSize: 16, spacing: 10, endPad: 50, messageIcon: 24, messageFont: NotchTheme.titleFont)
    static let compact = LyricsStyle(fontSize: 13, spacing: 7, endPad: 36, messageIcon: 18, messageFont: NotchTheme.captionFont)
}

/// 310 x 210 Home pane: now-playing header + transport + thin progress, synced lyrics below.
private struct LyricsDashboardPane: View {
    let store: LyricsStore

    var body: some View {
        let media = MediaService.shared
        if let track = media.track {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ArtworkView(image: track.artwork, size: 56, radius: 10)
                        .shadow(color: media.artworkTint.opacity(0.35), radius: 8, y: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: track.title, font: .system(size: 12, weight: .semibold))
                        Text(track.artist)
                            .font(NotchTheme.captionFont)
                            .foregroundStyle(NotchTheme.secondaryText)
                            .lineLimit(1)
                        MediaTransportControls(playSize: 13, sideSize: 10, spacing: 0)
                            .padding(.leading, -4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                MediaProgressBar()
                LyricsPane(state: store.state, trackKey: track.key, style: .compact, searchAgain: store.searchAgain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(NotchTheme.tertiaryText)
                Text("Nothing playing").font(NotchTheme.titleFont).foregroundStyle(NotchTheme.secondaryText)
                Text("Play something in Music or Spotify")
                    .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LyricsCompactLeading: View {
    var body: some View {
        ArtworkView(image: MediaService.shared.track?.artwork, size: 22, radius: 6)
    }
}

private struct LyricsSettings: View {
    var body: some View {
        MediaSourcePicker()
        Text("Lyrics come from LRCLIB and are cached in ~/Library/Application Support/NotchDeck/lyrics.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Expanded

private struct LyricsExpandedView: View {
    let store: LyricsStore

    var body: some View {
        let media = MediaService.shared
        if let track = media.track {
            HStack(spacing: 14) {
                VStack(spacing: 8) {
                    ArtworkView(image: track.artwork, size: 64, radius: 11)
                        .shadow(color: media.artworkTint.opacity(0.35), radius: 10, y: 3)
                    VStack(spacing: 1) {
                        MarqueeText(text: track.title, font: .system(size: 12, weight: .semibold))
                        Text(track.artist)
                            .font(NotchTheme.captionFont)
                            .foregroundStyle(NotchTheme.secondaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    MediaTransportControls(playSize: 15, sideSize: 11, spacing: 0)
                }
                .frame(width: 130)

                LyricsPane(state: store.state, trackKey: track.key, style: .full, searchAgain: store.searchAgain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MediaEmptyState()
        }
    }
}

private struct LyricsPane: View {
    let state: LyricsState
    let trackKey: String
    var style: LyricsStyle = .full
    var searchAgain: () -> Void = {}

    var body: some View {
        content
            .contextMenu { Button("Wrong lyrics? Search again", action: searchAgain) }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading lyrics\u{2026}").font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            message("quote.bubble", "No lyrics on LRCLIB", action: "Search again")
        case .unavailable:
            message("icloud.slash", "LRCLIB is busy \u{2014} retrying", action: "Retry now")
        case .instrumental:
            message("pianokeys", "Instrumental")
        case .plain(let text):
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not time-synced")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(NotchTheme.tertiaryText)
                    Text(text)
                        .font(.system(size: style.fontSize - 3, weight: .medium))
                        .foregroundStyle(NotchTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .mask(edgeFade)
        case .synced(let lines):
            SyncedLyricsView(lines: lines, style: style)
                .id(trackKey)
        }
    }

    private func message(_ symbol: String, _ text: String, action: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: style.messageIcon)).foregroundStyle(NotchTheme.tertiaryText)
            Text(text).font(style.messageFont).foregroundStyle(NotchTheme.secondaryText)
            if let action {
                Button(action, action: searchAgain)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(NotchTheme.surface))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                               .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

private struct SyncedLyricsView: View {
    let lines: [LRCLine]
    var style: LyricsStyle = .full
    @State private var current: Int = -1
    private let ticker = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: style.spacing) {
                    Color.clear.frame(height: style.endPad)
                    ForEach(lines) { line in
                        row(line)
                            .id(line.id)
                    }
                    Color.clear.frame(height: style.endPad)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask(edgeFade)
            .onAppear {
                update()
                if current >= 0 { proxy.scrollTo(current, anchor: .center) }
            }
            .onReceive(ticker) { _ in update() }
            .onChange(of: current) { _, new in
                guard new >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ line: LRCLine) -> some View {
        let dist = current < 0 ? 3 : abs(line.id - current)
        let isCurrent = line.id == current
        let opacity: Double = isCurrent ? 1 : (dist == 1 ? 0.5 : 0.28)
        return Text(line.text.isEmpty ? "\u{266A}" : line.text)
            .font(.system(size: style.fontSize, weight: .bold))
            .foregroundStyle(.white)
            .opacity(opacity)
            .scaleEffect(isCurrent ? 1 : 0.9, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { MediaService.shared.seek(to: line.time) }
            .animation(.easeInOut(duration: 0.3), value: isCurrent)
    }

    private func update() {
        let pos = MediaService.shared.currentPosition() + 0.1
        let idx = LRCParser.index(in: lines, at: pos) ?? -1
        if idx != current { current = idx }
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                               .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}
