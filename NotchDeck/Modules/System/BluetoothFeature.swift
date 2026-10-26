import Foundation
import SwiftUI
import IOBluetooth
import IOKit

/// Announces Bluetooth accessories connecting / disconnecting.
/// Devices that are already connected when the feature starts are tracked silently.
@MainActor
final class BluetoothFeature: SystemFeature {
    let kind: SystemFeatureKind = .bluetooth

    private var running = false
    private var connectToken: IOBluetoothUserNotification?
    private var disconnectTokens: [String: IOBluetoothUserNotification] = [:]
    private var connected: [String: String] = [:]   // address -> display name
    private var bridge: BluetoothBridge?

    func start() {
        guard !running else { return }
        running = true
        let bridge = BluetoothBridge(owner: self)
        self.bridge = bridge
        connectToken = IOBluetoothDevice.register(forConnectNotifications: bridge,
                                                  selector: #selector(BluetoothBridge.deviceConnected(_:device:)))
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for d in paired where d.isConnected() { track(d) }
        }
        refreshStatus()
    }

    func stop() {
        guard running else { return }
        running = false
        connectToken?.unregister(); connectToken = nil
        disconnectTokens.values.forEach { $0.unregister() }
        disconnectTokens.removeAll()
        connected.removeAll()
        bridge = nil
        SystemEvents.shared.setStatus(id: "bluetooth", symbol: "dot.radiowaves.left.and.right", text: nil)
    }

    // MARK: Events

    fileprivate func handleConnect(_ device: IOBluetoothDevice) {
        guard running, let address = device.addressString else { return }
        let isNew = connected[address] == nil
        track(device)
        refreshStatus()
        guard isNew else { return }
        let name = Self.displayName(device)
        post(device: device, name: name, connected: true, battery: nil)
        // Battery data shows up in the registry a moment after the link is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.connected[address] != nil,
                      let pct = Self.batteryPercent(address: address) else { return }
                self.post(device: device, name: name, connected: true, battery: pct)
            }
        }
    }

    fileprivate func handleDisconnect(_ device: IOBluetoothDevice) {
        guard running, let address = device.addressString else { return }
        disconnectTokens[address]?.unregister()
        disconnectTokens[address] = nil
        guard connected.removeValue(forKey: address) != nil else { return }
        refreshStatus()
        post(device: device, name: Self.displayName(device), connected: false, battery: nil)
    }

    private func track(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        connected[address] = Self.displayName(device)
        if disconnectTokens[address] == nil, let bridge {
            disconnectTokens[address] = device.register(forDisconnectNotification: bridge,
                                                        selector: #selector(BluetoothBridge.deviceDisconnected(_:device:)))
        }
    }

    private func post(device: IOBluetoothDevice, name: String, connected: Bool, battery: Int?) {
        var detail = connected ? "Connected" : "Disconnected"
        var level: Double?
        if let battery { detail += " · \(battery)%"; level = Double(battery) / 100 }
        SystemEvents.shared.post(SystemEvent(
            kind: .bluetooth, symbol: Self.symbol(for: name, device: device),
            tint: Color(red: 0.25, green: 0.55, blue: 1.0), title: name, detail: detail,
            level: level, duration: 3))
    }

    private func refreshStatus() {
        let n = connected.count
        SystemEvents.shared.setStatus(id: "bluetooth", symbol: "dot.radiowaves.left.and.right",
                                      text: "Bluetooth: \(n) connected")
    }

    // MARK: Helpers

    static func displayName(_ d: IOBluetoothDevice) -> String {
        let n = d.name ?? ""
        return n.isEmpty ? "Bluetooth device" : n
    }

    static func symbol(for name: String, device: IOBluetoothDevice) -> String {
        let n = name.lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") || n.contains("buds") || n.contains("headset") || n.contains("beats") { return "headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("magic mouse") { return "magicmouse" }
        if n.contains("mouse") { return "computermouse" }
        return "dot.radiowaves.left.and.right"
    }

    /// Normalises "AA-BB-cc:dd" style addresses to lowercase hex without separators.
    nonisolated static func normalize(_ address: String) -> String {
        address.lowercased().filter { $0.isHexDigit }
    }

    /// Best effort: searches HID services in the IORegistry for a matching address with a BatteryPercent.
    static func batteryPercent(address: String) -> Int? {
        let wanted = normalize(address)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard result == nil,
                  let addr = IORegistryEntryCreateCFProperty(entry, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  normalize(addr) == wanted,
                  let pct = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int, (0...100).contains(pct) else { continue }
            result = pct
        }
        return result
    }
}

/// Objective-C selector target for IOBluetooth notifications.
private final class BluetoothBridge: NSObject {
    weak var owner: BluetoothFeature?
    init(owner: BluetoothFeature) { self.owner = owner }

    @objc func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.owner?.handleConnect(device) }
        }
    }

    @objc func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.owner?.handleDisconnect(device) }
        }
    }
}
