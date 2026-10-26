import Foundation
import SwiftUI
import AppKit
import CoreAudio
import CoreMediaIO

/// "Microphone in use" / "Camera in use" indicators.
///
/// Only property reads and property listeners are used (CoreAudio `DeviceIsRunningSomewhere`,
/// CoreMediaIO `DeviceIsRunningSomewhere`); no capture session is ever opened, so no
/// camera / microphone permission prompt is triggered.
/// Note: the built-in microphone can read as "running" while dictation or Siri is active.
@MainActor
final class PrivacyFeature: SystemFeature {
    let kind: SystemFeatureKind = .privacy

    private var running = false
    private var micActive = false
    private var cameraActive = false

    // CoreAudio
    private var audioListeners: [(device: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = []
    private var audioDevicesBlock: AudioObjectPropertyListenerBlock?
    // CoreMediaIO
    private var cameraListeners: [(device: CMIOObjectID, block: CMIOObjectPropertyListenerBlock)] = []
    private var cameraDevicesBlock: CMIOObjectPropertyListenerBlock?

    func start() {
        guard !running else { return }
        running = true
        // Do not announce something that was already running before we started.
        installAudio()
        installCamera()
        micActive = Self.anyMicRunning(audioListeners.map { $0.device })
        cameraActive = Self.anyCameraRunning(cameraListeners.map { $0.device })
        apply(announce: false)
    }

    func stop() {
        guard running else { return }
        running = false
        removeAudio()
        removeCamera()
        micActive = false
        cameraActive = false
        let ev = SystemEvents.shared
        ev.removeIndicator(id: "mic"); ev.removeIndicator(id: "camera")
        ev.setStatus(id: "privacy.mic", symbol: "mic", text: nil)
        ev.setStatus(id: "privacy.camera", symbol: "video", text: nil)
    }

    // MARK: Evaluation

    private func evaluate() {
        guard running else { return }
        let mic = Self.anyMicRunning(audioListeners.map { $0.device })
        let cam = Self.anyCameraRunning(cameraListeners.map { $0.device })
        guard mic != micActive || cam != cameraActive else { return }
        let micStarted = mic && !micActive
        let camStarted = cam && !cameraActive
        micActive = mic; cameraActive = cam
        apply(announce: true, micStarted: micStarted, camStarted: camStarted)
    }

    private func apply(announce: Bool, micStarted: Bool = false, camStarted: Bool = false) {
        let ev = SystemEvents.shared
        if micActive {
            ev.setIndicator(id: "mic", rank: 41, view: AnyView(
                PrivacyDot(symbol: "mic.fill", tint: Color(red: 1.0, green: 0.62, blue: 0.20))))
        } else { ev.removeIndicator(id: "mic") }
        if cameraActive {
            ev.setIndicator(id: "camera", rank: 40, view: AnyView(
                PrivacyDot(symbol: "video.fill", tint: Color(red: 0.30, green: 0.85, blue: 0.45))))
        } else { ev.removeIndicator(id: "camera") }
        ev.setStatus(id: "privacy.mic", symbol: micActive ? "mic.fill" : "mic",
                     text: micActive ? "Microphone: in use" : "Microphone: idle")
        ev.setStatus(id: "privacy.camera", symbol: cameraActive ? "video.fill" : "video",
                     text: cameraActive ? "Camera: in use" : "Camera: idle")
        guard announce else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if camStarted {
            ev.post(SystemEvent(kind: .privacy, symbol: "video.fill", tint: Color(red: 0.30, green: 0.85, blue: 0.45),
                                title: "Camera in use", detail: app, duration: 2.5))
        } else if micStarted {
            ev.post(SystemEvent(kind: .privacy, symbol: "mic.fill", tint: Color(red: 1.0, green: 0.62, blue: 0.20),
                                title: "Microphone in use", detail: app, duration: 2.5))
        }
    }

    // MARK: CoreAudio

    private static func audioAddress(_ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func inputDevices() -> [AudioObjectID] {
        var addr = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = audioAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
        }
    }

    private static func audioRunning(_ id: AudioObjectID) -> Bool {
        var addr = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func anyMicRunning(_ ids: [AudioObjectID]) -> Bool { ids.contains(where: audioRunning) }

    private func installAudio() {
        removeAudioDeviceListeners()
        for id in Self.inputDevices() {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            var addr = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                audioListeners.append((id, block))
            }
        }
        if audioDevicesBlock == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.installAudio()
                    self.evaluate()
                }
            }
            var addr = Self.audioAddress(kAudioHardwarePropertyDevices)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block) == noErr {
                audioDevicesBlock = block
            }
        }
    }

    private func removeAudioDeviceListeners() {
        for l in audioListeners {
            var addr = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(l.device, &addr, DispatchQueue.main, l.block)
        }
        audioListeners.removeAll()
    }

    private func removeAudio() {
        removeAudioDeviceListeners()
        if let b = audioDevicesBlock {
            var addr = Self.audioAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, b)
            audioDevicesBlock = nil
        }
    }

    // MARK: CoreMediaIO

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var addr = cmioAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids
    }

    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var addr = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == 0 && value != 0
    }

    private static func anyCameraRunning(_ ids: [CMIOObjectID]) -> Bool { ids.contains(where: cameraRunning) }

    private func installCamera() {
        removeCameraDeviceListeners()
        for id in Self.cameraDevices() {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            var addr = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            if CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == 0 {
                cameraListeners.append((id, block))
            }
        }
        if cameraDevicesBlock == nil {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.installCamera()
                    self.evaluate()
                }
            }
            var addr = Self.cmioAddress(kCMIOHardwarePropertyDevices)
            if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main, block) == 0 {
                cameraDevicesBlock = block
            }
        }
    }

    private func removeCameraDeviceListeners() {
        for l in cameraListeners {
            var addr = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(l.device, &addr, DispatchQueue.main, l.block)
        }
        cameraListeners.removeAll()
    }

    private func removeCamera() {
        removeCameraDeviceListeners()
        if let b = cameraDevicesBlock {
            var addr = Self.cmioAddress(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, DispatchQueue.main, b)
            cameraDevicesBlock = nil
        }
    }
}

/// Small tinted glyph with a soft pulse, used for the collapsed-notch indicators.
private struct PrivacyDot: View {
    let symbol: String
    let tint: Color
    @State private var pulse = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(pulse ? 1 : 0.7)
            .frame(width: 22, height: 22)
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
    }
}
