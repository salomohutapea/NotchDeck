import SwiftUI
import IOKit.ps

/// Pure battery transition logic, kept free of IOKit so it can be tested on its own.
struct BatteryReading: Equatable {
    var percent: Int
    var onAC: Bool
    var charging: Bool
    var charged: Bool
    var minutesLeft: Int?
    var isFull: Bool { charged || (onAC && percent >= 100) }
}

enum BatteryChange: Equatable {
    case pluggedIn, unplugged, full, low20, low10
}

struct BatteryTracker {
    private(set) var last: BatteryReading?
    private var lowLevel = 0 // 0 none, 1 crossed 20, 2 crossed 10

    /// Feeds a reading and returns the event to announce, if any. The first reading never announces.
    mutating func update(_ r: BatteryReading) -> BatteryChange? {
        defer { last = r }
        guard let prev = last else {
            lowLevel = r.onAC ? 0 : Self.level(r.percent)
            return nil
        }
        if r.onAC || r.percent > 20 { lowLevel = 0 }
        if r.onAC != prev.onAC {
            if !r.onAC { lowLevel = Self.level(r.percent) }
            return r.onAC ? .pluggedIn : .unplugged
        }
        if r.isFull && !prev.isFull && r.onAC { return .full }
        if !r.onAC {
            let l = Self.level(r.percent)
            if l > lowLevel {
                lowLevel = l
                return l == 2 ? .low10 : .low20
            }
        }
        return nil
    }

    private static func level(_ p: Int) -> Int { p <= 10 ? 2 : (p <= 20 ? 1 : 0) }
}

@MainActor
final class BatteryFeature: SystemFeature {
    let kind: SystemFeatureKind = .battery
    private var source: CFRunLoopSource?
    private var tracker = BatteryTracker()

    func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let me = Unmanaged<BatteryFeature>.fromOpaque(raw).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, ctx)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        tracker = BatteryTracker()
        refresh()
    }

    func stop() {
        if let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            CFRunLoopSourceInvalidate(src)
        }
        source = nil
        tracker = BatteryTracker()
        SystemEvents.shared.setStatus(id: "battery", symbol: "battery.100", text: nil)
    }

    private func readBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = (d[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let mx = max(1, (d[kIOPSMaxCapacityKey] as? Int) ?? 100)
            let pct = min(100, max(0, Int((Double(cur) / Double(mx) * 100).rounded())))
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let charged = (d[kIOPSIsChargedKey] as? Bool) ?? false
            var mins: Int? = nil
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { mins = t }
            return BatteryReading(percent: pct, onAC: onAC, charging: charging, charged: charged, minutesLeft: mins)
        }
        return nil
    }

    private func refresh() {
        guard let r = readBattery() else { return }
        let change = tracker.update(r)
        let bus = SystemEvents.shared
        let level = Double(r.percent) / 100
        let pct = "\(r.percent)%"

        var status = pct
        if r.isFull && r.onAC { status += " · charged" }
        else if r.charging { status += " · charging" }
        else if r.onAC { status += " · plugged in" }
        else if let m = r.minutesLeft { status += String(format: " · %d:%02d left", m / 60, m % 60) }
        bus.setStatus(id: "battery", symbol: r.onAC ? "battery.100.bolt" : Self.symbol(r.percent), text: status)

        guard let change else { return }
        switch change {
        case .pluggedIn:
            bus.post(SystemEvent(kind: .battery, symbol: "battery.100.bolt", tint: NotchTheme.success,
                                 title: "Charging", detail: pct, level: level))
        case .unplugged:
            bus.post(SystemEvent(kind: .battery, symbol: Self.symbol(r.percent), tint: .white,
                                 title: "On battery", detail: pct, level: level))
        case .full:
            bus.post(SystemEvent(kind: .battery, symbol: "battery.100", tint: NotchTheme.success,
                                 title: "Battery full", detail: pct, level: level))
        case .low20:
            bus.post(SystemEvent(kind: .battery, symbol: "battery.25", tint: .orange,
                                 title: "Low battery", detail: pct, level: level, duration: 4))
        case .low10:
            bus.post(SystemEvent(kind: .battery, symbol: "battery.0", tint: NotchTheme.danger,
                                 title: "Low battery", detail: pct, level: level, duration: 4))
        }
    }

    private static func symbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
