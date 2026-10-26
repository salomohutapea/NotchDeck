import Foundation

/// Smart content classification for clipboard text. Pure Foundation so it can be unit-tested standalone.
enum ClipSmart: String, Codable {
    case plain, json, jwt, url, deeplink, hexColor, base64, uuid, path, stackTrace, code

    var badge: String {
        switch self {
        case .plain: return "TXT"
        case .json: return "JSON"
        case .jwt: return "JWT"
        case .url: return "URL"
        case .deeplink: return "LINK"
        case .hexColor: return "HEX"
        case .base64: return "B64"
        case .uuid: return "UUID"
        case .path: return "PATH"
        case .stackTrace: return "TRACE"
        case .code: return "CODE"
        }
    }
}

struct JWTInfo {
    var header: String
    var payload: String
    var expiry: Date?
    var expiryText: String?
}

enum ClipDetect {
    static func classify(_ raw: String) -> ClipSmart {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .plain }
        let singleLine = !s.contains("\n")
        if singleLine {
            if jwt(s) != nil { return .jwt }
            if UUID(uuidString: s) != nil { return .uuid }
            if hexColor(s) != nil { return .hexColor }
        }
        if (s.hasPrefix("{") || s.hasPrefix("[")), prettyJSON(s) != nil { return .json }
        if singleLine, !s.contains(where: { $0.isWhitespace }), let u = urlKind(s) { return u }
        if isStackTrace(s) { return .stackTrace }
        if singleLine, isPath(s) { return .path }
        if singleLine, decodeBase64(s) != nil { return .base64 }
        if isCode(s) { return .code }
        return .plain
    }

    // MARK: JSON

    static func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(obj),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    // MARK: JWT (decode only; never verified or altered)

    static func jwt(_ s: String) -> JWTInfo? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        for p in parts where p.unicodeScalars.contains(where: { !allowed.contains($0) }) { return nil }
        guard let hData = base64URLDecode(String(parts[0])), let pData = base64URLDecode(String(parts[1])),
              let h = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
              h["alg"] != nil || h["typ"] != nil,
              let p = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
              let hs = pretty(h), let ps = pretty(p) else { return nil }
        var info = JWTInfo(header: hs, payload: ps)
        if let exp = (p["exp"] as? NSNumber)?.doubleValue {
            let d = Date(timeIntervalSince1970: exp)
            info.expiry = d
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            let rel = f.localizedString(for: d, relativeTo: Date())
            info.expiryText = d > Date() ? "expires \(rel)" : "expired \(rel)"
        }
        return info
    }

    private static func pretty(_ obj: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: Base64

    static func decodeBase64(_ s: String) -> String? {
        guard s.count >= 12, s.count % 4 == 0 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard !s.unicodeScalars.contains(where: { !allowed.contains($0) }),
              let d = Data(base64Encoded: s), let str = String(data: d, encoding: .utf8), str.count >= 4 else { return nil }
        let printable = str.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0 == "\r" || ($0.value >= 32 && $0.value != 127) }.count
        guard Double(printable) / Double(str.unicodeScalars.count) > 0.97 else { return nil }
        return str
    }

    // MARK: Colour

    static func hexColor(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard s.hasPrefix("#") else { return nil }
        let h = String(s.dropFirst())
        guard h.count == 6 || h.count == 8 || h.count == 3,
              h.allSatisfy({ $0.isHexDigit }) else { return nil }
        var full = h
        if h.count == 3 { full = h.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(full, radix: 16) else { return nil }
        if full.count == 6 {
            return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, 1)
        }
        return (Double((v >> 24) & 255) / 255, Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    // MARK: URL / deep link

    static func urlKind(_ s: String) -> ClipSmart? {
        guard let r = s.range(of: "://"), r.lowerBound != s.startIndex else { return nil }
        let scheme = s[s.startIndex..<r.lowerBound]
        guard let f = scheme.first, f.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        guard s.count > scheme.count + 3 else { return nil }
        let l = scheme.lowercased()
        return (l == "http" || l == "https" || l == "ftp") ? .url : .deeplink
    }

    /// Short label for a URL: host (or scheme for deep links with no host) plus path.
    static func urlSummary(_ s: String) -> String {
        guard let c = URLComponents(string: s) else { return s }
        let host = c.host ?? ""
        let path = c.path
        if host.isEmpty { return "\(c.scheme ?? "")://\(path)" }
        let scheme = (c.scheme == "http" || c.scheme == "https") ? "" : "\(c.scheme ?? "")://"
        return scheme + host + (path == "/" ? "" : path)
    }

    // MARK: Path

    static func isPath(_ s: String) -> Bool {
        guard s.count < 1024, s.hasPrefix("/") || s.hasPrefix("~/") else { return false }
        let expanded = (s as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return s != "/" }
        guard s.range(of: #"^(~|/)[\w.\-+@ ]*(/[\w.\-+@ ]+)+/?$"#, options: .regularExpression) != nil else { return false }
        return !s.contains("  ")
    }

    // MARK: Stack trace

    static func isStackTrace(_ s: String) -> Bool {
        if s.contains("Traceback (most recent call last)") { return true }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        let pats = [#"^\s+at\s+\S+"#, #"^\s*#\d+\s+(0x[0-9a-fA-F]+|\S+ in )"#, #"File ".*", line \d+"#,
                    #"\.(swift|js|jsx|ts|tsx|java|kt|m|mm|py|rb|go|rs):\d+(:\d+)?"#, #"^\s*\d+\s+\S+\s+0x[0-9a-fA-F]+"#]
        var hits = 0
        for l in lines.prefix(60) {
            let line = String(l)
            if pats.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) { hits += 1 }
        }
        return hits >= 2
    }

    // MARK: Code heuristic

    static func isCode(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let kw = #"\b(func|function|const|let|var|import|export|class|struct|enum|return|def|interface|public|private|async|await|if|else|for|while)\b"#
        if lines.count == 1 {
            let l = lines[0]
            return l.range(of: #"^(const|let|var|import|export|func|def|class|struct|public|private|@\w+)\b.*[=;({:]"#, options: .regularExpression) != nil
        }
        var score = 0
        if s.range(of: kw, options: .regularExpression) != nil { score += 1 }
        if lines.contains(where: { $0.hasSuffix("{") || $0.hasSuffix(";") || $0.hasSuffix("}") || $0.hasSuffix("):") }) { score += 1 }
        if s.contains("=>") || s.contains("</") || s.contains("->") || s.contains("::") { score += 1 }
        if lines.filter({ $0.hasPrefix("  ") || $0.hasPrefix("\t") }).count >= 2 { score += 1 }
        return score >= 2
    }
}
