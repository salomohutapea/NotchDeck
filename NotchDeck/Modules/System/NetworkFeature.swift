import SwiftUI
import Network
import Darwin

@MainActor
final class NetworkFeature: SystemFeature {
    let kind: SystemFeatureKind = .network
    private var monitor: NWPathMonitor?
    private var online: Bool?
    private var vpn: Bool?

    func start() {
        guard monitor == nil else { return }
        online = nil
        vpn = nil
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let name = Self.interfaceName(path)
            let vpnUp = Self.vpnActive()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(online: ok, name: name, vpn: vpnUp) }
            }
        }
        monitor = m
        m.start(queue: DispatchQueue(label: "notchdeck.network", qos: .utility))
    }

    func stop() {
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        online = nil
        vpn = nil
        let bus = SystemEvents.shared
        bus.removeIndicator(id: "offline")
        bus.setStatus(id: "network", symbol: "wifi", text: nil)
        bus.setStatus(id: "vpn", symbol: "lock.shield", text: nil)
    }

    nonisolated private static func interfaceName(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "Offline" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        return "Online"
    }

    /// A utun interface that is up, running and has a routable (non link-local) IPv4 address.
    nonisolated private static func vpnActive() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            guard String(cString: p.pointee.ifa_name).hasPrefix("utun") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0xA9FE || ip == 0 { continue } // 169.254/16 link-local
            return true
        }
        return false
    }

    private func apply(online ok: Bool, name: String, vpn vpnUp: Bool) {
        guard monitor != nil else { return }
        let bus = SystemEvents.shared
        bus.setStatus(id: "network", symbol: ok ? "wifi" : "wifi.slash", text: "Network: \(name)")
        bus.setStatus(id: "vpn", symbol: "lock.shield", text: "VPN: \(vpnUp ? "on" : "off")")

        let prevOnline = online, prevVPN = vpn
        online = ok
        vpn = vpnUp

        if ok {
            bus.removeIndicator(id: "offline")
        } else {
            bus.setIndicator(id: "offline", rank: 44, view: AnyView(
                Image(systemName: "wifi.slash").font(.system(size: 14)).foregroundStyle(.orange)))
        }

        if let prev = prevOnline, prev != ok {
            if ok {
                bus.post(SystemEvent(kind: .network, symbol: "wifi", tint: NotchTheme.success, title: "Back online", detail: name))
            } else {
                bus.post(SystemEvent(kind: .network, symbol: "wifi.slash", tint: .orange, title: "Offline", detail: "No connection"))
            }
        }
        if let prev = prevVPN, prev != vpnUp {
            bus.post(SystemEvent(kind: .network, symbol: "lock.shield.fill", tint: NotchTheme.accent,
                                 title: vpnUp ? "VPN connected" : "VPN disconnected"))
        }
    }
}
