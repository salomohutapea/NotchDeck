import Foundation
import SwiftUI
import CoreGraphics

/// Best-effort screen recording indicator.  UNVERIFIED against a real recording.
///
/// Heuristics (polled every 1.5 s, only while the feature runs):
///  1. A status-bar-level window (layer 25, menu-bar height) owned by `screencaptureui` / `Control Center`
///     whose name mentions recording or stopping. Idle, this Mac shows no `screencaptureui` windows at all,
///     which is why the owner-only check is used for `screencaptureui` (its menu-bar stop item).
///  2. A running `screencapture` process started with a video flag (`-v`).
/// Two consecutive positive polls are required before announcing, to avoid flicker from the
/// screenshot selection UI (which also belongs to `screencaptureui`, but at other window layers).
@MainActor
final class RecordingFeature: SystemFeature {
    let kind: SystemFeatureKind = .recording

    private var running = false
    private var timer: Timer?
    private var active = false
    private var positives = 0
    private var cliProbeBusy = false
    private var cliRecording = false

    func start() {
        guard !running else { return }
        running = true
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll(announce: false)
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        active = false; positives = 0; cliRecording = false
        SystemEvents.shared.removeIndicator(id: "recording")
        SystemEvents.shared.setStatus(id: "recording", symbol: "record.circle", text: nil)
    }

    private func poll(announce: Bool = true) {
        guard running else { return }
        probeCLI()
        let detected = Self.windowIndicatesRecording() || cliRecording
        positives = detected ? positives + 1 : 0
        let now = positives >= (announce ? 2 : 1)
        guard now != active else { return }
        active = now
        let ev = SystemEvents.shared
        if now {
            ev.setIndicator(id: "recording", rank: 43, view: AnyView(RecordingDot()))
            ev.setStatus(id: "recording", symbol: "record.circle", text: "Screen recording: on")
            if announce {
                ev.post(SystemEvent(kind: .recording, symbol: "record.circle", tint: NotchTheme.danger,
                                    title: "Screen recording", duration: 2.5))
            }
        } else {
            ev.removeIndicator(id: "recording")
            ev.setStatus(id: "recording", symbol: "record.circle", text: nil)
            if announce {
                ev.post(SystemEvent(kind: .recording, symbol: "stop.circle", tint: .white,
                                    title: "Recording stopped", duration: 2.5))
            }
        }
    }

    // MARK: Heuristics

    private static func windowIndicatesRecording() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let name = (w[kCGWindowName as String] as? String ?? "").lowercased()
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let height = ((w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double) ?? 0
            let nameHit = name.contains("recording") || name.contains("stop recording")
            if owner == "screencaptureui", layer == 25, height > 0, height <= 40 { return true }
            if (owner == "screencaptureui" || owner == "control center"), nameHit { return true }
        }
        return false
    }

    /// Looks for `screencapture ... -v` without blocking the main thread.
    private func probeCLI() {
        guard !cliProbeBusy else { return }
        cliProbeBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", "^/usr/sbin/screencapture .*-[a-zA-Z]*v"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            var hit = false
            if (try? p.run()) != nil { p.waitUntilExit(); hit = p.terminationStatus == 0 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.cliRecording = hit
                    self?.cliProbeBusy = false
                }
            }
        }
    }
}

private struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Image(systemName: "record.circle")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(NotchTheme.danger)
            .opacity(pulse ? 1 : 0.55)
            .frame(width: 22, height: 22)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}
