import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1. Routes: POST /hook?agent=claude|codex, GET /health.
final class HookServer: @unchecked Sendable {
    enum State: Sendable { case listening(UInt16), failed(String) }

    var onEvent: (@Sendable (HookEvent) -> Void)?
    var onState: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "notchdeck.hookserver")
    private var listener: NWListener?

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState?(.failed("Invalid port \(port)")); return
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = false
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            onState?(.failed("Cannot listen on port \(port): \(error.localizedDescription)")); return
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            switch st {
            case .ready: self?.onState?(.listening(port))
            case .failed(let err):
                l?.cancel()
                var msg = "Listener failed: \(err.localizedDescription)"
                if case .posix(let code) = err, code == .EADDRINUSE { msg = "Port \(port) is already in use" }
                self?.onState?(.failed(msg))
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            HookConnection(conn, queue: self.queue, server: self).start()
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    fileprivate func route(method: String, target: String, body: Data) -> (Int, String) {
        let comps = URLComponents(string: "http://x" + target)
        switch (method, comps?.path ?? target) {
        case ("GET", "/health"): return (200, "OK")
        case ("POST", "/hook"):
            let agent = comps?.queryItems?.first(where: { $0.name == "agent" })?.value ?? "claude"
            if let ev = HookEvent.parse(agent: agent, body: body) { onEvent?(ev) }
            return (200, "OK")
        case (_, "/health"), (_, "/hook"): return (405, "Method Not Allowed")
        default: return (404, "Not Found")
        }
    }
}

private final class HookConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private unowned let server: HookServer
    private var buffer = Data()
    private var sentContinue = false
    private static let maxBody = 2_000_000

    init(_ c: NWConnection, queue: DispatchQueue, server: HookServer) {
        conn = c; self.queue = queue; self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [self] st in
            if case .failed = st { conn.cancel() }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [self] in conn.cancel() } // slow-client guard
        receive()
    }

    private enum Parsed { case need, request(String, String, Data), bad(Int, String) }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }
            switch parse() {
            case .need:
                if isComplete { conn.cancel() } else { receive() }
            case .request(let m, let t, let body):
                let (code, text) = server.route(method: m, target: t, body: body)
                respond(code, text)
            case .bad(let code, let text):
                respond(code, text)
            }
        }
    }

    private func parse() -> Parsed {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: sep) else {
            return buffer.count > 32_768 ? .bad(431, "Request Header Fields Too Large") : .need
        }
        let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return .bad(400, "Bad Request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .bad(411, "Length Required")
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maxBody else { return .bad(413, "Payload Too Large") }
        let have = buffer.count - (r.upperBound - buffer.startIndex)
        if have < length {
            if headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            return .need
        }
        let body = buffer.subdata(in: r.upperBound..<(r.upperBound + length))
        return .request(String(parts[0]), String(parts[1]), body)
    }

    private func respond(_ code: Int, _ text: String) {
        let resp = "HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(resp.utf8), contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [self] _ in conn.cancel() })
    }
}
