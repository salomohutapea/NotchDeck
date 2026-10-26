import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private struct Entry {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var idByHotKeyID: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private let signature: OSType = 0x4E44_4B59 // 'NDKY'

    private init() {}

    /// Registers (or replaces) the hotkey for `id`. Returns false if the system refused it
    /// (e.g. already taken by another app).
    @discardableResult
    func register(id: String, keyCode: UInt32, modifiers: NSEvent.ModifierFlags,
                  handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(id: id)
        installHandlerIfNeeded()
        let numeric = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, Self.carbonModifiers(modifiers),
                                         EventHotKeyID(signature: signature, id: numeric),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        entries[id] = Entry(ref: ref, handler: handler)
        idByHotKeyID[numeric] = id
        return true
    }

    func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
        idByHotKeyID = idByHotKeyID.filter { $0.value != id }
    }

    fileprivate func fire(numericID: UInt32) {
        guard let id = idByHotKeyID[numericID], let entry = entries[id] else { return }
        entry.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            let numeric = hkID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(numericID: numeric) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
