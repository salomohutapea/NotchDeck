import SwiftUI
import CoreAudio
import AudioToolbox

@MainActor
final class VolumeFeature: SystemFeature {
    let kind: SystemFeatureKind = .volume

    private var running = false
    private var device: AudioObjectID = 0
    private var deviceName = ""
    private var lastVolume: Double?
    private var lastMuted: Bool?

    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceAddresses: [AudioObjectPropertyAddress] = []

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private static func addr(_ sel: AudioObjectPropertySelector, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
    }

    func start() {
        guard !running else { return }
        running = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        systemBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main, block)
        attach(announce: false)
    }

    func stop() {
        guard running else { return }
        running = false
        if let b = systemBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, .main, b)
        }
        systemBlock = nil
        detach()
        SystemEvents.shared.setStatus(id: "volume", symbol: "speaker.wave.2.fill", text: nil)
    }

    // MARK: Device handling

    private func defaultDeviceChanged() { attach(announce: true) }

    private func detach() {
        if let b = deviceBlock, device != 0 {
            for var a in deviceAddresses { AudioObjectRemovePropertyListenerBlock(device, &a, .main, b) }
        }
        deviceBlock = nil
        deviceAddresses = []
        device = 0
    }

    private func attach(announce: Bool) {
        detach()
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &id) == noErr,
              id != 0 else {
            SystemEvents.shared.setStatus(id: "volume", symbol: "speaker.slash.fill", text: nil)
            return
        }
        device = id
        deviceName = Self.name(of: id)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.levelChanged() }
        }
        deviceBlock = block
        deviceAddresses = [
            Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            Self.addr(kAudioDevicePropertyVolumeScalar, 1),
            Self.addr(kAudioDevicePropertyVolumeScalar, 2),
            Self.addr(kAudioDevicePropertyMute),
        ]
        for var a in deviceAddresses { AudioObjectAddPropertyListenerBlock(id, &a, .main, block) }

        lastVolume = readVolume()
        lastMuted = readMuted()
        updateStatus()
        if announce {
            let n = deviceName.lowercased()
            let headphones = ["headphone", "airpods", "buds"].contains { n.contains($0) }
            SystemEvents.shared.post(SystemEvent(
                kind: .volume, symbol: headphones ? "headphones" : "speaker.wave.2.fill",
                title: deviceName.isEmpty ? "Output changed" : deviceName, detail: "Output", duration: 1.8))
        }
    }

    // MARK: Reading

    private func readFloat(_ a: AudioObjectPropertyAddress) -> Double? {
        var a = a
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr, v.isFinite else { return nil }
        return Double(min(1, max(0, v)))
    }

    private func readVolume() -> Double? {
        if let v = readFloat(Self.addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)) { return v }
        let ch = [1, 2].compactMap { readFloat(Self.addr(kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0))) }
        return ch.isEmpty ? nil : ch.reduce(0, +) / Double(ch.count)
    }

    private func readMuted() -> Bool? {
        var a = Self.addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    private static func name(of id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "" }
        return s as String
    }

    // MARK: Changes

    private func levelChanged() {
        guard device != 0 else { return }
        let v = readVolume(), m = readMuted()
        defer { lastVolume = v; lastMuted = m; updateStatus() }
        guard v != lastVolume || m != lastMuted else { return }
        let level = v ?? 0
        let muted = m ?? false
        let symbol = muted ? "speaker.slash.fill" : (level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        SystemEvents.shared.post(SystemEvent(
            kind: .volume, symbol: symbol, title: muted ? "Muted" : "Volume",
            detail: muted ? nil : "\(Int((level * 100).rounded()))%", level: muted ? 0 : level, duration: 1.6))
    }

    private func updateStatus() {
        var text = (lastMuted ?? false) ? "Muted" : (lastVolume.map { "Volume \(Int(($0 * 100).rounded()))%" } ?? "Volume")
        if !deviceName.isEmpty { text += " · \(deviceName)" }
        SystemEvents.shared.setStatus(id: "volume", symbol: (lastMuted ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill", text: text)
    }
}
