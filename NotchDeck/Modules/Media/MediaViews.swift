import SwiftUI
import AppKit

func formatMediaTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Rounded artwork with a music-note placeholder.
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(NotchTheme.surfaceStrong)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(NotchTheme.tertiaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: image)
    }
}

struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 16
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.88))
                .frame(width: size * 1.9, height: size * 1.6)
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// prev / play-pause / next.
struct MediaTransportControls: View {
    var playSize: CGFloat = 24
    var sideSize: CGFloat = 16
    var spacing: CGFloat = 10

    var body: some View {
        let media = MediaService.shared
        HStack(spacing: spacing) {
            TransportButton(symbol: "backward.fill", size: sideSize) { media.previous() }
            TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: playSize) { media.playPause() }
            TransportButton(symbol: "forward.fill", size: sideSize) { media.next() }
        }
    }
}

/// Scrubbable progress bar with elapsed / remaining labels.
struct MediaProgressBar: View {
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        let media = MediaService.shared
        TimelineView(.animation(minimumInterval: 0.1, paused: !media.isPlaying || dragFraction != nil)) { tl in
            let dur = media.track?.duration ?? 0
            let pos = dragFraction.map { $0 * dur } ?? media.currentPosition(at: tl.date)
            let fraction = dur > 0 ? min(1, max(0, pos / dur)) : 0
            VStack(spacing: 3) {
                bar(fraction: fraction, enabled: dur > 0, duration: dur, tint: media.artworkTint)
                HStack {
                    Text(formatMediaTime(pos))
                    Spacer()
                    Text(dur > 0 ? "-" + formatMediaTime(max(0, dur - pos)) : "--:--")
                }
                .font(NotchTheme.monoFont)
                .foregroundStyle(NotchTheme.tertiaryText)
            }
        }
    }

    private func bar(fraction: Double, enabled: Bool, duration: TimeInterval, tint: Color) -> some View {
        GeometryReader { g in
            let h: CGFloat = (hovering || dragFraction != nil) ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: h)
                Capsule().fill(tint).frame(width: max(h, g.size.width * fraction), height: h)
                    .opacity(enabled ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled, g.size.width > 0 else { return }
                        dragFraction = min(1, max(0, v.location.x / g.size.width))
                    }
                    .onEnded { v in
                        guard enabled, g.size.width > 0 else { dragFraction = nil; return }
                        let f = min(1, max(0, v.location.x / g.size.width))
                        MediaService.shared.seek(to: f * duration)
                        dragFraction = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: h)
        }
        .frame(height: 14)
    }
}

/// Shown when no player has a track.
struct MediaEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(NotchTheme.tertiaryText)
            Text("Nothing playing")
                .font(NotchTheme.titleFont)
                .foregroundStyle(NotchTheme.secondaryText)
            Text("Play something in Music or Spotify")
                .font(NotchTheme.captionFont)
                .foregroundStyle(NotchTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared preferred-source picker used in settings.
struct MediaSourcePicker: View {
    @AppStorage(MediaPreference.key) private var raw = "auto"
    var body: some View {
        Picker("Preferred source", selection: $raw) {
            Text("Automatic").tag("auto")
            Text("Music").tag("music")
            Text("Spotify").tag("spotify")
        }
        .onChange(of: raw) { _, _ in MediaService.shared.scheduleRefresh() }
    }
}
