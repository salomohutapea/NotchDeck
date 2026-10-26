import Foundation

struct LRCLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    /// Parses LRC text. Supports multiple timestamps per line, `[offset:ms]`,
    /// `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]` and strips enhanced `<mm:ss.xx>` word tags.
    static func parse(_ text: String) -> [LRCLine] {
        var offset: TimeInterval = 0
        var raw: [(TimeInterval, String)] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                if let t = timestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let v = tag.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(v.hasPrefix("+") ? String(v.dropFirst()) : v) { offset = ms / 1000 }
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let body = stripWordTags(String(rest)).trimmingCharacters(in: .whitespaces)
            for t in times { raw.append((t, body)) }
        }

        // Stable sort by time.
        let sorted = raw.enumerated().sorted { a, b in
            a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset
        }.map(\.element)
        return sorted.enumerated().map { LRCLine(id: $0.offset, time: max(0, $0.element.0 - offset), text: $0.element.1) }
    }

    /// Index of the line active at `position` (nil before the first line).
    static func index(in lines: [LRCLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private static func timestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let m = Int(parts[0]), m >= 0 else { return nil }
        let secPart = parts[1].replacingOccurrences(of: ",", with: ".")
        guard let s = Double(secPart), s >= 0, secPart.first?.isNumber == true else { return nil }
        return Double(m) * 60 + s
    }

    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">"), timestamp(String(s[s.index(after: i)..<close])) != nil {
                i = s.index(after: close)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    #if DEBUG
    /// Returns a list of failures (empty = pass).
    @discardableResult
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ cond: Bool, _ msg: String) { if !cond { fails.append(msg) } }
        func near(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 0.0005 }

        let a = parse("[ar:Foo]\n[ti:Bar]\n[00:12.34]Hello\n[01:02]Min\n[00:03.500]Ms")
        check(a.count == 3, "count a=\(a.count)")
        check(near(a[0].time, 3.5) && a[0].text == "Ms", "a0")
        check(near(a[1].time, 12.34) && a[1].text == "Hello", "a1")
        check(near(a[2].time, 62) && a[2].text == "Min", "a2")

        let b = parse("[00:20.00][00:10.5]Chorus")
        check(b.count == 2 && near(b[0].time, 10.5) && near(b[1].time, 20) && b[1].text == "Chorus", "multi")

        let c = parse("[offset:+500]\n[00:10.00]X")
        check(c.count == 1 && near(c[0].time, 9.5), "offset+")
        let d = parse("[offset:-500]\n[00:10.00]X")
        check(d.count == 1 && near(d[0].time, 10.5), "offset-")

        let e = parse("[00:05.00]\n[00:06.00]Line")
        check(e.count == 2 && e[0].text.isEmpty, "empty line kept")

        let f = parse("[00:20.00]<00:20.10>word <00:20.50>two")
        check(f.first?.text == "word two", "word tags: \(f.first?.text ?? "nil")")

        let g = parse("[00:01.00]a\r\n[00:02.00]b\r\n")
        check(g.count == 2, "crlf")

        check(index(in: a, at: 2) == nil, "index before first")
        check(index(in: a, at: 3.5) == 0 && index(in: a, at: 13) == 1 && index(in: a, at: 999) == 2, "index")
        assert(fails.isEmpty, "LRCParser.selfTest failed: \(fails)")
        return fails
    }
    #endif
}
