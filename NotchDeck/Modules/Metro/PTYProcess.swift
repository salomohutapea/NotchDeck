import Foundation
import Darwin

enum TermColor: Hashable, Sendable {
    /// xterm 256-colour palette index (0-15 are the ANSI colours).
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct TermStyle: Hashable, Sendable {
    var fg: TermColor? = nil
    var bg: TermColor? = nil
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    static let plain = TermStyle()
}

struct TermRun: Hashable, Sendable {
    var text: String
    var style: TermStyle
}

/// One rendered terminal line: plain text plus styled runs.
struct TermLine: Hashable, Sendable {
    var text: String
    var runs: [TermRun]
    var isStyled: Bool { runs.contains { $0.style != .plain } }
    static func plain(_ s: String) -> TermLine { TermLine(text: s, runs: s.isEmpty ? [] : [TermRun(text: s, style: .plain)]) }
}

/// A small terminal emulator for display: keeps a growing list of lines and a cursor, understands the
/// sequences progress bars use (CR, cursor up/down, erase line, column moves) so repeated status updates
/// overwrite their line, and SGR colours / bold / underline. Titles and other sequences are ignored.
struct TerminalScreen {
    private struct Cell { var ch: Character; var style: TermStyle }
    private var lines: [[Cell]] = [[]]
    /// Rendered form of each line; nil = changed since last snapshot.
    private var cache: [TermLine?] = [nil]
    private var row = 0
    private var col = 0
    private var cur: [Cell] = []
    private var pen = TermStyle.plain
    private enum Mode { case text, esc, csi, osc, oscEsc, skipOne }
    private var mode = Mode.text
    private var csiBuf = ""
    private var carry = [UInt8]()
    private static let maxLines = 3000

    mutating func feed(_ data: Data) {
        var bytes = carry + [UInt8](data)
        carry = []
        // Keep an incomplete trailing UTF-8 sequence for the next chunk.
        var cut = bytes.count
        var i = bytes.count - 1, back = 0
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
            if b >= 0xC0 {
                let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
                if bytes.count - i < need { cut = i }
            }
            break
        }
        if cut < bytes.count { carry = Array(bytes[cut...]); bytes = Array(bytes[..<cut]) }
        for u in String(decoding: bytes, as: UTF8.self).unicodeScalars { consume(u) }
    }

    /// The screen contents (trailing empty lines dropped).
    mutating func snapshot() -> [TermLine] {
        commit()
        var out: [TermLine] = []
        out.reserveCapacity(lines.count)
        for i in lines.indices {
            if let c = cache[i] { out.append(c); continue }
            let r = Self.render(lines[i])
            cache[i] = r
            out.append(r)
        }
        while out.count > 1, out.last?.text.isEmpty == true { out.removeLast() }
        return out
    }

    /// Plain text only (tests / logs).
    mutating func textSnapshot() -> [String] { snapshot().map(\.text) }

    private static func render(_ cells: [Cell]) -> TermLine {
        var runs: [TermRun] = []
        var text = ""
        for c in cells {
            text.append(c.ch)
            if let last = runs.last, last.style == c.style { runs[runs.count - 1].text.append(c.ch) }
            else { runs.append(TermRun(text: String(c.ch), style: c.style)) }
        }
        return TermLine(text: text, runs: runs)
    }

    // MARK: Rows

    private mutating func commit() { lines[row] = cur; cache[row] = nil }

    private mutating func moveRow(to target: Int) {
        commit()
        let t = max(0, target)
        while lines.count <= t { lines.append([]); cache.append(nil) }
        row = t
        cur = lines[t]
        if lines.count > Self.maxLines {
            let drop = lines.count - Self.maxLines + 500
            lines.removeFirst(drop)
            cache.removeFirst(drop)
            row = max(0, row - drop)
            cur = lines[row]
        }
    }

    private mutating func put(_ ch: Character) {
        let cell = Cell(ch: ch, style: pen)
        if col < cur.count { cur[col] = cell }
        else {
            while cur.count < col { cur.append(Cell(ch: " ", style: .plain)) }
            cur.append(cell)
        }
        col += 1
    }

    // MARK: Parser

    private mutating func consume(_ u: Unicode.Scalar) {
        switch mode {
        case .esc:
            switch u {
            case "[": mode = .csi; csiBuf = ""
            case "]": mode = .osc
            case "(", ")", "#": mode = .skipOne
            default: mode = .text
            }
            return
        case .csi:
            if u.value >= 0x40 && u.value <= 0x7E { mode = .text; csi(final: u) }
            else { csiBuf.unicodeScalars.append(u) }
            return
        case .osc:
            if u.value == 7 { mode = .text } else if u.value == 0x1B { mode = .oscEsc }
            return
        case .oscEsc:
            mode = u == "\\" ? .text : .osc
            return
        case .skipOne:
            mode = .text
            return
        case .text:
            break
        }
        switch u {
        case "\u{1B}": mode = .esc
        case "\n": moveRow(to: row + 1); col = 0
        case "\r": col = 0
        case "\u{8}": col = max(0, col - 1)
        case "\t": repeat { put(" ") } while col % 8 != 0
        default:
            if u.value < 0x20 || u.value == 0x7F { return }
            put(Character(u))
        }
    }

    private mutating func csi(final f: Unicode.Scalar) {
        if csiBuf.hasPrefix("?") || csiBuf.hasPrefix(">") || csiBuf.hasPrefix("=") { return }   // private modes
        let params = csiBuf.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let first = params.first ?? nil
        let n = max(1, first ?? 1)
        switch f {
        case "m": sgr()
        case "A": moveRow(to: row - n)
        case "B": moveRow(to: row + n)
        case "E": moveRow(to: row + n); col = 0
        case "F": moveRow(to: row - n); col = 0
        case "G": col = max(0, n - 1)
        case "C": col += n
        case "D": col = max(0, col - n)
        case "K":
            switch first ?? 0 {
            case 0: if col < cur.count { cur.removeSubrange(col...) }
            case 1: for i in 0..<min(col + 1, cur.count) { cur[i] = Cell(ch: " ", style: .plain) }
            default: cur = []
            }
        case "J":
            switch first ?? 0 {
            case 0:
                if col < cur.count { cur.removeSubrange(col...) }
                commit()
                if lines.count > row + 1 {
                    lines.removeSubrange((row + 1)...)
                    cache.removeSubrange((row + 1)...)
                }
            case 2, 3:
                lines = [[]]; cache = [nil]; row = 0; cur = []; col = 0
            default: break
            }
        default: break   // cursor save/restore, absolute positioning: ignored
        }
    }

    /// Select Graphic Rendition: colours and attributes.
    private mutating func sgr() {
        let p = csiBuf.split(whereSeparator: { $0 == ";" || $0 == ":" }).map { Int($0) ?? 0 }
        if p.isEmpty { pen = .plain; return }
        var i = 0
        func extended() -> TermColor? {
            guard i + 1 < p.count else { return nil }
            if p[i + 1] == 5, i + 2 < p.count { i += 2; return .indexed(UInt8(clamping: p[i])) }
            if p[i + 1] == 2, i + 4 < p.count {
                defer { i += 4 }
                return .rgb(UInt8(clamping: p[i + 2]), UInt8(clamping: p[i + 3]), UInt8(clamping: p[i + 4]))
            }
            return nil
        }
        while i < p.count {
            let v = p[i]
            switch v {
            case 0: pen = .plain
            case 1: pen.bold = true
            case 2: pen.dim = true
            case 3: pen.italic = true
            case 4: pen.underline = true
            case 7: pen.inverse = true
            case 22: pen.bold = false; pen.dim = false
            case 23: pen.italic = false
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 30...37: pen.fg = .indexed(UInt8(v - 30))
            case 38: pen.fg = extended()
            case 39: pen.fg = nil
            case 40...47: pen.bg = .indexed(UInt8(v - 40))
            case 48: pen.bg = extended()
            case 49: pen.bg = nil
            case 90...97: pen.fg = .indexed(UInt8(v - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(v - 100 + 8))
            default: break
            }
            i += 1
        }
    }
}

/// A child process attached to a pseudo-terminal: `/bin/zsh -ilc <command>` as session + group leader.
/// Output is teed raw to a log file and delivered as stripped lines. All callbacks arrive on the main queue.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let master: Int32
    private let queue = DispatchQueue(label: "notchdeck.pty", qos: .utility)
    private var source: DispatchSourceRead?
    private var screen = TerminalScreen()
    private var logHandle: FileHandle?
    private var closed = false
    private let lock = NSLock()
    private var exited = false

    var onScreen: (([TermLine]) -> Void)?
    var onExit: ((Int32) -> Void)?

    struct SpawnError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func spawn(command: String, cwd: String, logURL: URL?, logHeader: String? = nil, cols: UInt16 = 120, rows: UInt16 = 40,
                      extraEnv: [String: String] = [:]) throws -> PTYProcess {
        var master: Int32 = 0, slave: Int32 = 0
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &win) == 0 else { throw SpawnError(message: "openpty failed (\(errno))") }
        guard let namePtr = ptsname(master) else { close(master); close(slave); throw SpawnError(message: "ptsname failed") }
        let slaveName = String(cString: namePtr)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        // Opening the slave by name after setsid makes it the controlling terminal where the kernel allows it.
        posix_spawn_file_actions_addopen(&fa, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = String(cols); env["LINES"] = String(rows)
        env["NOTCHDECK"] = "1"
        env.removeValue(forKey: "NO_COLOR")
        for (k, v) in extraEnv { env[k] = v }
        // Spelled out step by step: older compilers cannot type-check the one-line form.
        let envStrings: [String] = env.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        envp.append(nil)
        let argStrings: [String] = ["/bin/zsh", "-ilc", command]
        var argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
        argv.append(nil)
        defer { envp.forEach { free($0) }; argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fa, &attr, argv, envp)
        close(slave)
        guard rc == 0 else {
            close(master)
            throw SpawnError(message: "spawn failed: \(String(cString: strerror(rc)))")
        }
        let p = PTYProcess(pid: pid, master: master)
        if let logURL {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: logHeader?.data(using: .utf8))
            p.logHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? p.logHandle?.seekToEnd()
        }
        p.begin()
        return p
    }

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    private func begin() {
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        source = src
        src.resume()
        // Reap on a dedicated thread, then drain what is left in the pty.
        let pid = self.pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            let code: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
            self?.queue.asyncAfter(deadline: .now() + 0.15) { self?.finish(code) }
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 16384)
        var total: [Data] = []
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 { total.append(Data(buf[0..<n])) }
            else {
                if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { source?.cancel() }
                break
            }
        }
        guard !total.isEmpty else { return }
        let data = total.reduce(into: Data()) { $0.append($1) }
        try? logHandle?.write(contentsOf: data)
        screen.feed(data)
        let snap = screen.snapshot()
        DispatchQueue.main.async { [weak self] in self?.onScreen?(snap) }
    }

    private func finish(_ code: Int32) {
        readAvailable()
        lock.lock(); if exited { lock.unlock(); return }; exited = true; lock.unlock()
        source?.cancel(); source = nil
        closeMaster()
        try? logHandle?.close(); logHandle = nil
        DispatchQueue.main.async { [weak self] in self?.onExit?(code) }
    }

    private func closeMaster() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(master)
    }

    var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }

    // MARK: Input / signals

    func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    /// Tell the program the visible terminal size (SIGWINCH).
    func resize(cols: UInt16, rows: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &win)
    }

    /// Process group of the shell plus every descendant (some tools put children in their own groups).
    func allPIDs() -> [pid_t] { [pid] + Self.descendants(of: pid) }

    static func descendants(of root: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [root]
        while let p = queue.popLast() {
            let cap = 256
            var buf = [pid_t](repeating: 0, count: cap)
            let n = proc_listchildpids(p, &buf, Int32(cap * MemoryLayout<pid_t>.size))
            guard n > 0 else { continue }
            for c in buf.prefix(Int(n)) where c > 0 { out.append(c); queue.append(c) }
        }
        return out
    }

    func signalAll(_ sig: Int32) {
        guard pid > 1 else { return }
        killpg(pid, sig)
        for c in Self.descendants(of: pid) { kill(c, sig) }
    }

    func sendCtrlC() {
        write("\u{03}")
        signalAll(SIGINT)
    }
}
