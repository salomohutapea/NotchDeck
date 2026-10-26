import SwiftUI
import Observation

/// "System": battery, volume, brightness, network, Bluetooth, privacy, downloads and recording events.
/// Events appear as compact peek banners; ongoing states as small icons in the collapsed notch.
@MainActor @Observable
final class SystemModule: NotchModule {
    let id: ModuleID = .system
    var compactPriority: Int { SystemEvents.shared.indicators.isEmpty ? 0 : 40 }
    var isLive: Bool { !SystemEvents.shared.indicators.isEmpty }

    @ObservationIgnored private var features: [any SystemFeature] = []
    @ObservationIgnored private var running: Set<SystemFeatureKind> = []
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    init() {}

    func start() {
        started = true
        if features.isEmpty { features = makeSystemFeatures() }
        syncFeatures()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFeatures() }
        }
    }

    func stop() {
        started = false
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o); defaultsObserver = nil }
        for f in features where running.contains(f.kind) { f.stop() }
        MediaKeyInterceptor.shared.stop()
        running.removeAll()
    }

    /// Start / stop each feature according to its toggle.
    private func syncFeatures() {
        guard started else { return }
        for f in features {
            let want = f.kind.isEnabled
            if want, !running.contains(f.kind) { running.insert(f.kind); f.start() }
            else if !want, running.contains(f.kind) { running.remove(f.kind); f.stop() }
        }
        if MediaKeyInterceptor.isEnabled { MediaKeyInterceptor.shared.start() } else { MediaKeyInterceptor.shared.stop() }
    }

    // MARK: Views

    func compactItems() -> [CompactItem] {
        SystemEvents.shared.indicators.map {
            CompactItem(id: "system.\($0.id)", rank: $0.rank,
                        view: AnyView($0.view.frame(width: CompactItem.iconSize, height: CompactItem.iconSize)))
        }
    }

    func compactLeading() -> AnyView {
        AnyView(SystemEvents.shared.indicators.first?.view ?? AnyView(EmptyView()))
    }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }

    func peekContent() -> AnyView? {
        guard SystemEvents.shared.current != nil else { return nil }
        return AnyView(SystemPeekRow())
    }

    func expanded() -> AnyView { AnyView(SystemExpandedView()) }
    func settings() -> AnyView? { AnyView(SystemSettingsView()) }
}

// MARK: - Peek row

private struct SystemPeekRow: View {
    var body: some View {
        if let e = SystemEvents.shared.current {
            HStack(spacing: 8) {
                Image(systemName: e.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(e.tint)
                    .frame(width: 20)
                Text(e.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let d = e.detail {
                    Text(d).font(.system(size: 12, weight: .medium)).foregroundStyle(NotchTheme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let level = e.level {
                    if e.kind == .volume || e.kind == .brightness {
                        LevelScrubber(kind: e.kind, level: level, tint: e.tint)
                    } else {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            GeometryReader { g in
                                Capsule().fill(e.tint).frame(width: max(4, g.size.width * min(1, max(0, level))))
                            }
                        }
                        .frame(width: 70, height: 5)
                        .animation(.easeOut(duration: 0.15), value: level)
                    }
                }
            }
            .id(e.id)
        }
    }
}

/// Volume / brightness bar in the banner: drag or click to set the level.
struct LevelScrubber: View {
    let kind: SystemFeatureKind
    let level: Double
    let tint: Color
    var width: CGFloat = 110
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        GeometryReader { g in
            let h: CGFloat = dragging || hover ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(h, g.size.width * min(1, max(0, level))))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    SystemEvents.shared.scrub(kind, to: v.location.x / max(1, g.size.width))
                }
                .onEnded { _ in
                    dragging = false
                    SystemEvents.shared.endScrub()
                })
            .animation(.easeOut(duration: 0.12), value: h)
        }
        .frame(width: width, height: 18)
        .onHover { hover = $0 }
        .help(kind == .volume ? "Drag to change the volume" : "Drag to change the brightness")
    }
}

/// Compact system-change indicator for the expanded notch's tab bar.
struct SystemHeaderToast: View {
    var body: some View {
        if let e = SystemEvents.shared.toast {
            HStack(spacing: 6) {
                Image(systemName: e.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(e.tint)
                    .frame(width: 14)
                ViewThatFits(in: .horizontal) {
                    full(e)
                    short(e)
                    EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(NotchTheme.surface))
            .onHover { SystemEvents.shared.toastHovered = $0 }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .help(e.title + (e.detail.map { " " + $0 } ?? ""))
        }
    }

    private func full(_ e: SystemEvent) -> some View {
        HStack(spacing: 6) {
            Text(e.detail ?? e.title).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).fixedSize()
            if let level = e.level, e.kind == .volume || e.kind == .brightness {
                LevelScrubber(kind: e.kind, level: level, tint: e.tint, width: 64)
            } else if let level = e.level {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 40, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(e.tint).frame(width: max(4, 40 * level), height: 4) }
            }
        }
    }

    private func short(_ e: SystemEvent) -> some View {
        Text(e.detail ?? e.title).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white).lineLimit(1).fixedSize()
    }
}

// MARK: - Expanded + settings

private struct SystemExpandedView: View {
    var body: some View {
        let lines = SystemEvents.shared.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ModuleID.system.systemImage).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                Text("System").font(NotchTheme.titleFont).foregroundStyle(.white)
            }
            if lines.isEmpty {
                Text("Nothing to report yet.").font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], alignment: .leading, spacing: 8) {
                    ForEach(lines) { l in
                        HStack(spacing: 8) {
                            Image(systemName: l.symbol).frame(width: 18).foregroundStyle(NotchTheme.secondaryText)
                            Text(l.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(NotchTheme.surface))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        // Fill exactly the content area so a wide grid can't push the header past the clipped edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SystemSettingsView: View {
    var body: some View {
        ForEach(SystemFeatureKind.allCases) { kind in
            FeatureToggle(kind: kind)
        }
        ReplaceHUDToggle()
        Text("Events appear as a short banner; downloads, camera/microphone use and screen recording stay as icons in the collapsed notch while active.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct FeatureToggle: View {
    let kind: SystemFeatureKind
    @AppStorage private var on: Bool
    init(kind: SystemFeatureKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, kind.defaultsKey)
    }
    var body: some View { Toggle(kind.title, isOn: $on) }
}

private struct ReplaceHUDToggle: View {
    @AppStorage(MediaKeyInterceptor.defaultsKey) private var on = false
    @State private var trusted = MediaKeyInterceptor.hasPermission
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Toggle("Replace the macOS volume and brightness pop-up", isOn: $on)
            .onChange(of: on) { _, new in if new && !trusted { MediaKeyInterceptor.requestPermission() } }
        if on && !trusted {
            HStack {
                Text("Needs Accessibility permission to intercept the volume and brightness keys.")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") {
                    MediaKeyInterceptor.requestPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .onReceive(poll) { _ in trusted = MediaKeyInterceptor.hasPermission }
        }
    }
}
