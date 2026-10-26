import SwiftUI
import Observation

@MainActor @Observable
final class NowPlayingModule: NotchModule {
    let id: ModuleID = .nowPlaying
    private(set) var isLive = false
    var compactPriority = 50

    @ObservationIgnored private let media = MediaService.shared
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastKey: String?

    init() {}

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        media.acquire()
        lastKey = media.track?.key
        sync(peek: false)
        arm(generation)
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        media.release()
        isLive = false
        lastKey = nil
    }

    private func arm(_ gen: Int) {
        withObservationTracking {
            _ = media.track?.key
            _ = media.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == gen else { return }
                self.sync(peek: true)
                self.arm(gen)
            }
        }
    }

    private func sync(peek: Bool) {
        let live = media.track != nil && media.isPlaying
        if isLive != live { isLive = live }
        let key = media.track?.key
        defer { lastKey = key }
        guard peek, let key, let last = lastKey, key != last, media.isPlaying else { return }
        let enabled = UserDefaults.standard.object(forKey: "nowPlaying.peekOnTrackChange") as? Bool ?? true
        if enabled { NotchCoordinator.shared.peek(.nowPlaying, duration: 4) }
    }

    // MARK: Views

    func compactLeading() -> AnyView { AnyView(NowPlayingCompactLeading()) }
    func compactTrailing() -> AnyView { AnyView(NowPlayingCompactTrailing()) }
    func expanded() -> AnyView { AnyView(NowPlayingExpandedView()) }
    func settings() -> AnyView? { AnyView(NowPlayingSettings()) }
    func peekContent() -> AnyView? { AnyView(NowPlayingPeekRow()) }
}

// MARK: - Compact

private struct NowPlayingCompactLeading: View {
    var body: some View {
        let media = MediaService.shared
        ArtworkView(image: media.track?.artwork, size: 22, radius: 6)
    }
}

private struct NowPlayingCompactTrailing: View {
    @AppStorage("nowPlaying.showEqualizer") private var showEqualizer = true
    var body: some View {
        let media = MediaService.shared
        if showEqualizer {
            EqualizerBars(tint: media.artworkTint, animating: media.isPlaying)
        }
    }
}

private struct NowPlayingPeekRow: View {
    @AppStorage("nowPlaying.showEqualizer") private var showEqualizer = true
    var body: some View {
        let media = MediaService.shared
        HStack(spacing: 8) {
            ArtworkView(image: media.track?.artwork, size: 24, radius: 6)
            if let track = media.track {
                let title = track.title.isEmpty ? "Unknown" : track.title
                HStack(spacing: 0) {
                    MarqueeText(text: track.artist.isEmpty ? title : title + " \u{2014} " + track.artist,
                                font: .system(size: 12.5, weight: .semibold))
                }
            } else {
                Spacer(minLength: 0)
            }
            if showEqualizer {
                EqualizerBars(tint: media.artworkTint, animating: media.isPlaying)
                    .scaleEffect(0.75)
                    .frame(width: 22, height: 18)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct EqualizerBars: View {
    var tint: Color
    var animating: Bool
    private let phases: [Double] = [0.0, 1.7, 0.6, 2.4, 1.1]
    private let speeds: [Double] = [7.2, 5.6, 8.4, 6.3, 7.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animating)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    let v = animating ? (sin(t * speeds[i] + phases[i]) + 1) / 2 : 0
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: animating ? 4 + 14 * v : 4)
                }
            }
            .frame(height: 18)
        }
    }
}

// MARK: - Expanded

private struct NowPlayingExpandedView: View {
    var body: some View {
        let media = MediaService.shared
        if let track = media.track {
            HStack(spacing: 18) {
                ArtworkView(image: track.artwork, size: 96, radius: 14)
                    .shadow(color: media.artworkTint.opacity(0.4), radius: 14, y: 4)
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: track.title.isEmpty ? "Unknown" : track.title,
                                font: .system(size: 16, weight: .semibold))
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " \u{2014} "))
                        .font(NotchTheme.bodyFont)
                        .foregroundStyle(NotchTheme.secondaryText)
                        .lineLimit(1)
                        .padding(.top, 2)
                    Spacer(minLength: 6)
                    MediaProgressBar()
                    HStack {
                        Label(track.source.appName, systemImage: track.source.symbol)
                            .font(NotchTheme.captionFont)
                            .foregroundStyle(NotchTheme.tertiaryText)
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MediaTransportControls(playSize: 24, sideSize: 16, spacing: 8)
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 100)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MediaEmptyState()
        }
    }
}

// MARK: - Settings

private struct NowPlayingSettings: View {
    @AppStorage("nowPlaying.showEqualizer") private var showEqualizer = true
    @AppStorage("nowPlaying.peekOnTrackChange") private var peek = true
    var body: some View {
        Toggle("Show equalizer in collapsed notch", isOn: $showEqualizer)
        Toggle("Peek when the track changes", isOn: $peek)
        MediaSourcePicker()
    }
}
