import AppKit
import CoreAudio
import AudioToolbox
import Darwin

/// Swallows the volume / brightness / mute keys so macOS does not show its own HUD, and applies
/// the change itself (the Volume / Brightness features then show NotchDeck's banner).
/// Needs Accessibility permission for the event tap; without it the keys keep their system behaviour.
@MainActor
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()
    static let defaultsKey = "system.replaceHUD"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    // NX_KEYTYPE_* (IOKit/hidsystem/ev_keymap.h)
    private static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    // Brightness keys on Apple keyboards also arrive as plain key events.
    private static let brightnessUpKeyCode: Int64 = 144, brightnessDownKeyCode: Int64 = 145

    /// Last time a brightness key was pressed (here or seen by the Brightness feature's monitor).
    static var lastBrightnessKey = Date.distantPast

    private init() {}

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (adds NotchDeck to the list).
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard tap == nil else { return }
        guard Self.hasPermission else {
            // Permission is often granted after the toggle is switched on: keep checking.
            if retryTimer == nil {
                let t = Timer(timeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if Self.hasPermission { MediaKeyInterceptor.shared.start() }
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                retryTimer = t
            }
            return
        }
        retryTimer?.invalidate(); retryTimer = nil
        let mask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Returns true when the event was handled and must be swallowed.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let flags = event.flags
        // ⌥ alone opens Sound / Displays settings: leave that to the system. ⌥⇧ = fine steps.
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        if flags.contains(.maskAlternate) && !fine { return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return false }
        let step = fine ? 1.0 / 64 : 1.0 / 16

        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == Self.brightnessUpKeyCode || code == Self.brightnessDownKeyCode else { return false }
            guard SystemBrightness.isAvailable else { return false }
            Self.lastBrightnessKey = Date()
            if type == .keyDown { SystemBrightness.change(by: code == Self.brightnessUpKeyCode ? step : -step) }
            return true
        }

        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let data = ns.data1
        let key = (data & 0xFFFF_0000) >> 16
        let down = ((data & 0xFF00) >> 8) == 0xA
        switch key {
        case Self.soundUp, Self.soundDown, Self.mute:
            guard SystemVolume.device() != nil else { return false }
            if down {
                if key == Self.mute { SystemVolume.toggleMute() } else { SystemVolume.change(by: key == Self.soundUp ? step : -step) }
            }
            return true
        case Self.brightnessUp, Self.brightnessDown:
            guard SystemBrightness.isAvailable else { return false }
            Self.lastBrightnessKey = Date()
            if down { SystemBrightness.change(by: key == Self.brightnessUp ? step : -step) }
            return true
        default:
            return false
        }
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyInterceptor.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let swallow = MainActor.assumeIsolated { MediaKeyInterceptor.shared.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: Output volume (default device)

@MainActor
enum SystemVolume {
    static func device() -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func addr(_ sel: AudioObjectPropertySelector, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
    }

    private static func settable(_ dev: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var ok = DarwinBoolean(false)
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &ok) == noErr && ok.boolValue
    }

    private static func readFloat(_ dev: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Float? {
        var a = a
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func writeFloat(_ dev: AudioObjectID, _ a: AudioObjectPropertyAddress, _ v: Float) {
        var a = a
        var v = v
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private static func muted(_ dev: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    private static func setMuted(_ dev: AudioObjectID, _ on: Bool) {
        let a = addr(kAudioDevicePropertyMute)
        guard settable(dev, a) else { return }
        var a2 = a
        var v = UInt32(on ? 1 : 0)
        AudioObjectSetPropertyData(dev, &a2, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    /// Set the output volume (0...1) directly, e.g. from the banner slider. 0 mutes, anything else unmutes.
    static func set(_ level: Double) {
        guard let dev = device() else { return }
        let target = Float(min(1, max(0, level)))
        let main = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if settable(dev, main) { writeFloat(dev, main, target) }
        else {
            for c in [1, 2].map({ addr(kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0)) }) where settable(dev, c) {
                writeFloat(dev, c, target)
            }
        }
        setMuted(dev, target == 0)
    }

    static func toggleMute() {
        guard let dev = device() else { return }
        setMuted(dev, !muted(dev))
    }

    static func change(by delta: Double) {
        guard let dev = device() else { return }
        let main = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let channels = [1, 2].map { addr(kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0)) }
        let current: Float
        if let v = readFloat(dev, main) { current = v }
        else {
            let vs = channels.compactMap { readFloat(dev, $0) }
            guard !vs.isEmpty else { return }
            current = vs.reduce(0, +) / Float(vs.count)
        }
        // Snap to the step grid like the system does.
        let steps = (Double(current) / abs(delta)).rounded() + (delta > 0 ? 1 : -1)
        let target = Float(min(1, max(0, steps * abs(delta))))
        if settable(dev, main) { writeFloat(dev, main, target) }
        else { for c in channels where settable(dev, c) { writeFloat(dev, c, target) } }
        if muted(dev) && delta > 0 { setMuted(dev, false) }
        if target == 0 && delta < 0 { setMuted(dev, true) }
        if target == current { announceVolume(target, muted: muted(dev)) }
    }

    /// The Volume feature only reacts to changes; at the limits nothing changes, so announce here.
    private static func announceVolume(_ v: Float, muted: Bool) {
        let level = Double(v)
        SystemEvents.shared.post(SystemEvent(
            kind: .volume, symbol: muted ? "speaker.slash.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"),
            title: muted ? "Muted" : "Volume", detail: muted ? nil : "\(Int((level * 100).rounded()))%",
            level: muted ? 0 : level, duration: 1.6))
    }
}

// MARK: Built-in display brightness

@MainActor
enum SystemBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private static var loaded = false
    private static var getFn: GetFn?
    private static var setFn: SetFn?

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"),
              let s = dlsym(h, "DisplayServicesSetBrightness") else { return }
        getFn = unsafeBitCast(g, to: GetFn.self)
        setFn = unsafeBitCast(s, to: SetFn.self)
    }

    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Only the built-in display is handled; external displays keep the system behaviour.
    static var isAvailable: Bool {
        load()
        return setFn != nil && builtinDisplay() != nil
    }

    /// Set the built-in display brightness (0...1) directly, e.g. from the banner slider.
    static func set(_ level: Double) {
        load()
        guard let set = setFn, let d = builtinDisplay() else { return }
        _ = set(d, Float(min(1, max(0, level))))
    }

    static func change(by delta: Double) {
        load()
        guard let get = getFn, let set = setFn, let d = builtinDisplay() else { return }
        var v: Float = 0
        guard get(d, &v) == 0 else { return }
        let steps = (Double(v) / abs(delta)).rounded() + (delta > 0 ? 1 : -1)
        let target = Float(min(1, max(0, steps * abs(delta))))
        _ = set(d, target)
        if target == v {
            let level = Double(target)
            SystemEvents.shared.post(SystemEvent(
                kind: .brightness, symbol: level < 0.4 ? "sun.min.fill" : "sun.max.fill", tint: .yellow,
                title: "Brightness", detail: "\(Int((level * 100).rounded()))%", level: level, duration: 1.6))
        }
    }
}
