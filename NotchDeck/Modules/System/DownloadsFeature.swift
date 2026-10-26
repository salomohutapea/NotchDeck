import Foundation
import SwiftUI

/// Pure helpers for recognising and measuring browser downloads (unit-testable, no I/O except `safariProgress(plistData:)`).
enum DownloadParsing {
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "opdownload"]

    /// "report.pdf.crdownload" -> ("report.pdf", "crdownload"). Nil if it is not a partial-download name.
    static func finalName(ofPartial name: String) -> (name: String, ext: String)? {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        guard partialExtensions.contains(ext) else { return nil }
        let base = ns.deletingPathExtension
        guard !base.isEmpty, base != "." else { return nil }
        return (base, ext)
    }

    /// Reads a Safari `.download` bundle Info.plist. Returns bytes so far and the total (nil if unknown or zero).
    static func safariProgress(plistData: Data) -> (bytes: Int64, total: Int64?)? {
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        func number(_ key: String) -> Int64? {
            if let n = dict[key] as? NSNumber { return n.int64Value }
            return nil
        }
        let total = number("DownloadEntryProgressTotalToLoad")
        let bytes = number("DownloadEntryProgressBytesSoFar") ?? 0
        return (max(0, bytes), (total ?? 0) > 0 ? total : nil)
    }

    static func fraction(bytes: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    /// Exponentially smoothed bytes/second.
    static func smoothedSpeed(previous: Double, deltaBytes: Int64, deltaSeconds: Double) -> Double {
        guard deltaSeconds > 0.05 else { return previous }
        let instant = Double(max(0, deltaBytes)) / deltaSeconds
        return previous <= 0 ? instant : previous * 0.6 + instant * 0.4
    }
}

/// Shows an icon with a progress ring in the collapsed notch while a browser download is in progress,
/// and announces when one finishes. Watches `~/Downloads` for `.crdownload`, `.download` (Safari bundle),
/// `.part` and `.opdownload` files. Nothing is touched while the feature is off.
@MainActor
final class DownloadsFeature: SystemFeature {
    let kind: SystemFeatureKind = .downloads

    private struct Active {
        var path: URL
        var finalName: String
        var bytes: Int64
        var total: Int64?
        var speed: Double = 0
        var lastSample: Date
    }

    private var running = false
    private var timer: Timer?
    private var watchSource: DispatchSourceFileSystemObject?
    private var active: [String: Active] = [:]            // keyed by partial file name
    private var pendingFinish: [String: Int] = [:]        // final name -> remaining checks
    private var shownKey = ""
    private var failedScans = 0
    private var skipTicks = 0

    private var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    }

    func start() {
        guard !running else { return }
        running = true
        installWatch()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick(announceFinishes: false)
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        watchSource?.cancel(); watchSource = nil
        active.removeAll(); pendingFinish.removeAll()
        shownKey = ""; failedScans = 0; skipTicks = 0
        SystemEvents.shared.removeIndicator(id: "downloads")
        SystemEvents.shared.setStatus(id: "downloads", symbol: "arrow.down.circle", text: nil)
    }

    private func installWatch() {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }   // no access: the timer path will simply find nothing
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchSource = src
    }

    // MARK: Scanning

    private func tick(announceFinishes: Bool = true) {
        guard running else { return }
        if skipTicks > 0 { skipTicks -= 1; return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else {
            // Likely permission denied: back off instead of hammering the folder.
            failedScans += 1
            skipTicks = min(60, 5 * failedScans)
            if !active.isEmpty { active.removeAll(); refreshUI() }
            return
        }
        failedScans = 0
        let now = Date()
        var seen: [String: Active] = [:]
        var names = Set<String>()
        for url in items {
            let name = url.lastPathComponent
            names.insert(name)
            guard let parts = DownloadParsing.finalName(ofPartial: name) else { continue }
            var bytes: Int64 = 0
            var total: Int64?
            if parts.ext == "download" {
                let plist = url.appendingPathComponent("Info.plist")
                if let data = try? Data(contentsOf: plist), let p = DownloadParsing.safariProgress(plistData: data) {
                    bytes = p.bytes; total = p.total
                }
                if bytes == 0 { bytes = Self.directorySize(url, fm: fm) }
            } else {
                bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            var entry = active[name] ?? Active(path: url, finalName: parts.name, bytes: bytes, total: total, speed: 0, lastSample: now)
            if active[name] != nil {
                entry.speed = DownloadParsing.smoothedSpeed(previous: entry.speed, deltaBytes: bytes - entry.bytes,
                                                            deltaSeconds: now.timeIntervalSince(entry.lastSample))
                entry.bytes = bytes; entry.total = total ?? entry.total; entry.lastSample = now
            }
            seen[name] = entry
        }
        // Partials that disappeared: finished if the final file now exists.
        for (name, gone) in active where seen[name] == nil { pendingFinish[gone.finalName] = 3 }
        active = seen
        for (final, left) in pendingFinish {
            if names.contains(final) {
                pendingFinish[final] = nil
                if announceFinishes { announceFinished(final) }
            } else if left <= 1 {
                pendingFinish[final] = nil      // cancelled / moved away
            } else {
                pendingFinish[final] = left - 1
            }
        }
        refreshUI()
    }

    private static func directorySize(_ url: URL, fm: FileManager) -> Int64 {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let u as URL in en { sum += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return sum
    }

    // MARK: UI

    private func announceFinished(_ name: String) {
        SystemEvents.shared.post(SystemEvent(kind: .downloads, symbol: "arrow.down.circle.fill",
                                             tint: NotchTheme.success, title: "Download finished",
                                             detail: name, duration: 3.5))
    }

    private func refreshUI() {
        let ev = SystemEvents.shared
        guard !active.isEmpty else {
            if !shownKey.isEmpty { ev.removeIndicator(id: "downloads"); shownKey = "" }
            ev.setStatus(id: "downloads", symbol: "arrow.down.circle", text: nil)
            return
        }
        // Aggregate over the downloads with a known size; spinner if none has one.
        let known = active.values.filter { ($0.total ?? 0) > 0 }
        let progress: Double? = known.isEmpty ? nil
            : DownloadParsing.fraction(bytes: known.reduce(0) { $0 + $1.bytes }, total: known.reduce(0) { $0 + ($1.total ?? 0) })
        let key = progress.map { String(Int($0 * 100)) } ?? "spin"
        if key != shownKey {
            shownKey = key
            ev.setIndicator(id: "downloads", rank: 42, view: AnyView(DownloadRingIcon(progress: progress)))
        }
        ev.setStatus(id: "downloads", symbol: "arrow.down.circle", text: "Downloads: \(active.count) active")
    }
}

private struct DownloadRingIcon: View {
    let progress: Double?
    private let tint = Color(red: 0.35, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
            if let p = progress {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.8)
                Circle().trim(from: 0, to: max(0.03, p))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: p)
                    .frame(width: 20, height: 20)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 360))
                }
                .frame(width: 20, height: 20)
            }
        }
        .frame(width: 22, height: 22)
    }
}
