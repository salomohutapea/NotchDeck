import SwiftUI
import Observation

/// What a system feature can announce. One per toggle in Settings > System.
enum SystemFeatureKind: String, CaseIterable, Identifiable {
    case battery, volume, brightness, network, bluetooth, privacy, downloads, recording
    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "Battery and charging"
        case .volume: return "Volume"
        case .brightness: return "Brightness"
        case .network: return "Network and VPN"
        case .bluetooth: return "Bluetooth devices"
        case .privacy: return "Microphone and camera in use"
        case .downloads: return "Downloads"
        case .recording: return "Screen recording"
        }
    }

    /// UserDefaults key; on by default.
    var defaultsKey: String { "system.\(rawValue)" }
    var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
}

/// A short-lived announcement shown as a compact peek banner.
struct SystemEvent: Identifiable, Equatable {
    let id = UUID()
    var kind: SystemFeatureKind
    var symbol: String
    var tint: Color = .white
    var title: String
    var detail: String? = nil
    /// 0...1: draws a small level bar (volume, brightness, battery).
    var level: Double? = nil
    var duration: TimeInterval = 3
}

/// A small icon that stays in the collapsed notch while something is ongoing (download, mic in use, ...).
struct SystemIndicator: Identifiable {
    let id: String
    /// Lower = closer to the notch. Music 10-11, AI 20-21, builds 30-32; use 40+ here.
    var rank: Int
    var view: AnyView
}

/// A line in the System tab ("Battery 82% charging").
struct SystemStatusLine: Identifiable {
    let id: String
    var symbol: String
    var text: String
}

/// Shared bus between the features (producers) and `SystemModule` (peek / compact / expanded views).
@MainActor @Observable
final class SystemEvents {
    static let shared = SystemEvents()
    private init() {}

    private(set) var current: SystemEvent?
    private(set) var indicators: [SystemIndicator] = []
    private(set) var status: [SystemStatusLine] = []

    /// Announce something. Ignored if the feature is switched off. Repeated posts (volume keys held down)
    /// just replace the content of the running peek.
    func post(_ event: SystemEvent) {
        guard event.kind.isEnabled else { return }
        if scrubbing != nil, var cur = current, cur.kind == event.kind {
            // The banner slider is being dragged: update in place (same id keeps the gesture alive).
            cur.symbol = event.symbol; cur.title = event.title; cur.detail = event.detail; cur.level = event.level
            current = cur
            if toast?.kind == cur.kind { toast = cur }
            return
        }
        current = event
        if NotchCoordinator.shared.state == .expanded { showToast(event); return }
        NotchCoordinator.shared.peek(.system, duration: event.duration,
                                     holdOnHover: event.level != nil && (event.kind == .volume || event.kind == .brightness))
    }

    /// Event shown in the expanded notch's tab bar (peeks can't show while the notch is open).
    private(set) var toast: SystemEvent?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private func showToast(_ event: SystemEvent) {
        toast = event
        scheduleToastEnd(after: max(event.duration, 2))
    }

    private func scheduleToastEnd(after d: TimeInterval) {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(d))
            guard !Task.isCancelled, let self else { return }
            if self.scrubbing != nil || self.toastHovered { self.scheduleToastEnd(after: 1); return }
            self.toast = nil
        }
    }

    @ObservationIgnored var toastHovered = false

    /// Kind whose banner slider is being dragged, if any.
    var scrubbing: SystemFeatureKind?

    /// Banner slider moved: apply the level and reflect it right away.
    func scrub(_ kind: SystemFeatureKind, to level: Double) {
        let level = min(1, max(0, level))
        scrubbing = kind
        switch kind {
        case .volume: SystemVolume.set(level)
        case .brightness: SystemBrightness.set(level)
        default: return
        }
        guard var cur = current, cur.kind == kind else { return }
        cur.level = level
        cur.detail = "\(Int((level * 100).rounded()))%"
        if kind == .volume {
            cur.title = level == 0 ? "Muted" : "Volume"
            cur.symbol = level == 0 ? "speaker.slash.fill" : (level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
            if level == 0 { cur.detail = nil }
        } else {
            cur.symbol = level < 0.4 ? "sun.min.fill" : "sun.max.fill"
        }
        current = cur
        if toast?.kind == kind { toast = cur }
    }

    func endScrub() { scrubbing = nil }

    /// Add or update a collapsed-notch icon.
    func setIndicator(id: String, rank: Int, view: AnyView) {
        let item = SystemIndicator(id: id, rank: rank, view: view)
        if let i = indicators.firstIndex(where: { $0.id == id }) { indicators[i] = item } else { indicators.append(item) }
    }

    func removeIndicator(id: String) {
        indicators.removeAll { $0.id == id }
    }

    /// Add or update a line of the System tab; pass nil text to remove it.
    func setStatus(id: String, symbol: String, text: String?) {
        guard let text else { status.removeAll { $0.id == id }; return }
        let line = SystemStatusLine(id: id, symbol: symbol, text: text)
        if let i = status.firstIndex(where: { $0.id == id }) { status[i] = line } else { status.append(line) }
        status.sort { $0.id < $1.id }
    }
}

/// One monitor (battery, volume, ...). `start()` / `stop()` are called when the module or the feature's toggle changes.
@MainActor
protocol SystemFeature: AnyObject {
    var kind: SystemFeatureKind { get }
    func start()
    func stop()
}

@MainActor
func makeSystemFeatures() -> [any SystemFeature] {
    [BatteryFeature(), VolumeFeature(), BrightnessFeature(), NetworkFeature(),
     BluetoothFeature(), PrivacyFeature(), DownloadsFeature(), RecordingFeature()]
}
