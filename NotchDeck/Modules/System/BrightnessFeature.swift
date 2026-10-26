import SwiftUI
import Darwin

@MainActor
final class BrightnessFeature: SystemFeature {
    let kind: SystemFeatureKind = .brightness

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private var getBrightness: GetFn?
    private var handle: UnsafeMutableRawPointer?
    private var timer: Timer?
    private var lastValue: Float?
    private var displayID: UInt32 = 0
    private var keyMonitor: Any?

    func start() {
        guard timer == nil else { return }
        guard loadSymbols() else { return }
        lastValue = nil
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Brightness keys mark a change as user-made; automatic (ambient light) changes stay silent.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .keyDown]) { e in
            let isKey: Bool
            if e.type == .keyDown { isKey = e.keyCode == 144 || e.keyCode == 145 }
            else { isKey = e.subtype.rawValue == 8 && [2, 3].contains((e.data1 & 0xFFFF_0000) >> 16) }
            if isKey { MainActor.assumeIsolated { MediaKeyInterceptor.lastBrightnessKey = Date() } }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        lastValue = nil
        if let h = handle { dlclose(h) }
        handle = nil
        getBrightness = nil
    }

    private func loadSymbols() -> Bool {
        if getBrightness != nil { return true }
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let h = dlopen(path, RTLD_LAZY) else { return false }
        guard let sym = dlsym(h, "DisplayServicesGetBrightness") else { dlclose(h); return false }
        // Built-in display only: bail out on Macs without one.
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(8, &ids, &n) == .success,
              let builtin = ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { dlclose(h); return false }
        displayID = builtin
        handle = h
        getBrightness = unsafeBitCast(sym, to: GetFn.self)
        return true
    }

    private func tick() {
        guard let get = getBrightness else { return }
        var v: Float = 0
        guard get(displayID, &v) == 0, v.isFinite else { return }
        defer { lastValue = v }
        guard let prev = lastValue, abs(v - prev) >= 0.01 else { return }
        // Ambient-light adjustments drift in small steps; key presses and the Control Center slider
        // either come with a key event or jump noticeably within one tick.
        let fromKey = Date().timeIntervalSince(MediaKeyInterceptor.lastBrightnessKey) < 1.5
        guard fromKey || abs(v - prev) >= 0.06 else { return }
        let level = Double(min(1, max(0, v)))
        SystemEvents.shared.post(SystemEvent(
            kind: .brightness, symbol: level < 0.4 ? "sun.min.fill" : "sun.max.fill", tint: .yellow,
            title: "Brightness", detail: "\(Int((level * 100).rounded()))%", level: level, duration: 1.6))
    }
}
