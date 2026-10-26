import SwiftUI
import AppKit

/// Live output of a Devtools command, shown inside the notch (replaces the Devtools / Home content
/// until "back" is pressed). A finished command's view closes itself when the notch collapses.
struct TerminalOutputView: View {
    let module: MetroModule
    let cmd: DevCommand

    var body: some View {
        let run = module.runner.run(for: cmd.id)
        VStack(spacing: 0) {
            header(run)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            TerminalLines(module: module, cmd: cmd, run: run)
        }
        .onDisappear {
            if !(module.runner.run(for: cmd.id)?.state.isRunning ?? false) { module.closeTerminal() }
        }
    }

    private func header(_ run: CommandRun?) -> some View {
        let state = run?.state ?? .idle
        return HStack(spacing: 6) {
            DevIconButton(symbol: "chevron.left", help: "Back", minWidth: 24, height: 22) { module.closeTerminal() }
                .fixedSize()
            Image(systemName: cmd.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(devCyan)
            Text(cmd.name).font(NotchTheme.titleFont).foregroundStyle(.white).lineLimit(1)
            status(state)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if state.isRunning {
                    DevIconButton(symbol: "return", help: "Send Return", minWidth: 24, height: 22) { module.runner.send(cmd.id, text: "\r") }
                    DevIconButton(symbol: "stop.fill", help: "Stop", tint: NotchTheme.danger, minWidth: 24, height: 22) { module.stop(cmd) }
                } else {
                    DevIconButton(symbol: "arrow.clockwise", help: "Run again", minWidth: 24, height: 22) { module.run(cmd) }
                }
                DevIconButton(symbol: "doc.on.doc", help: "Copy output", enabled: !(run?.allLines.isEmpty ?? true), minWidth: 24, height: 22) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((run?.allLines ?? []).joined(separator: "\n"), forType: .string)
                }
                DevIconButton(symbol: "arrow.up.forward.app", help: "Open log in Terminal", minWidth: 24, height: 22) { module.openLog(cmd) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private func status(_ state: RunState) -> some View {
        switch state {
        case .running(_, let since):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(devClock(tl.date.timeIntervalSince(since)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(NotchTheme.secondaryText)
                }
            }
        case .succeeded(let d):
            Label(devClock(d), systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchTheme.success)
        case .failed(let code, _, let d):
            Label("exit \(code) \u{00B7} \(devClock(d))", systemImage: "xmark.circle.fill")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchTheme.danger)
        case .idle:
            EmptyView()
        }
    }
}

private struct TerminalLines: View {
    let module: MetroModule
    let cmd: DevCommand
    let run: CommandRun?
    @State private var focused = false
    private static let visibleLines = 1500
    static let fontSize: CGFloat = 11
    private static let cell: CGSize = {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let w = ("M" as NSString).size(withAttributes: [.font: f]).width
        return CGSize(width: w, height: ceil(f.ascender - f.descender + f.leading))
    }()

    var body: some View {
        let _ = run?.revision   // subscribe to output changes
        let lines = Array((run?.styledLines ?? []).suffix(Self.visibleLines))
        let running = run?.state.isRunning == true
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if lines.isEmpty {
                    Text(running ? "Waiting for output\u{2026}" : "No output yet")
                        .font(NotchTheme.captionFont).foregroundStyle(NotchTheme.tertiaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                    Text(TerminalStyle.attributed(line))
                                        .font(.system(size: Self.fontSize, design: .monospaced))
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(i)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .onChange(of: run?.revision) { _, _ in
                            proxy.scrollTo(lines.count - 1, anchor: .bottom)
                        }
                        .onAppear {
                            DispatchQueue.main.async { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                        }
                    }
                }
                if running {
                    TerminalKeyCatcher(focused: $focused) { module.runner.send(cmd.id, text: $0) }
                        .frame(width: 1, height: 1)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if running { TerminalKeyCatcher.focusRequest &+= 1 } })
            .overlay(alignment: .bottomTrailing) {
                if running {
                    Text(focused ? "Typing goes to \(cmd.name)" : "Click to type")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(focused ? devCyan : NotchTheme.tertiaryText)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(devCyan.opacity(focused && running ? 0.35 : 0), lineWidth: 1))
            .onAppear { resize(g.size) }
            .onChange(of: g.size) { _, new in resize(new) }
            .onChange(of: running) { _, _ in resize(g.size) }
        }
    }

    private func resize(_ size: CGSize) {
        let cols = Int((size.width - 20) / Self.cell.width)
        let rows = Int((size.height - 12) / Self.cell.height)
        module.runner.resize(cmd.id, cols: cols, rows: rows)
    }
}

/// ANSI palette and SGR attributes -> AttributedString.
enum TerminalStyle {
    static let defaultFG = Color.white.opacity(0.86)

    private static let ansi: [(Double, Double, Double)] = [
        (0.30, 0.30, 0.33), (0.94, 0.36, 0.34), (0.36, 0.82, 0.46), (0.93, 0.78, 0.33),
        (0.40, 0.60, 1.00), (0.80, 0.48, 0.95), (0.33, 0.82, 0.90), (0.82, 0.82, 0.84),
        (0.52, 0.52, 0.56), (1.00, 0.47, 0.45), (0.50, 0.93, 0.58), (1.00, 0.88, 0.45),
        (0.55, 0.72, 1.00), (0.90, 0.62, 1.00), (0.48, 0.92, 0.98), (1.00, 1.00, 1.00),
    ]

    static func color(_ c: TermColor) -> Color {
        switch c {
        case .rgb(let r, let g, let b): return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let i):
            if i < 16 { let a = ansi[Int(i)]; return Color(red: a.0, green: a.1, blue: a.2) }
            if i >= 232 { let v = (8 + 10 * Double(i - 232)) / 255; return Color(red: v, green: v, blue: v) }
            let n = Int(i) - 16
            let steps: [Double] = [0, 95, 135, 175, 215, 255]
            return Color(red: steps[n / 36] / 255, green: steps[(n / 6) % 6] / 255, blue: steps[n % 6] / 255)
        }
    }

    /// Lines without any colour keep the old keyword tint (errors red, warnings amber).
    static func attributed(_ line: TermLine) -> AttributedString {
        if line.text.isEmpty { return AttributedString(" ") }
        if !line.isStyled {
            var a = AttributedString(line.text)
            a.foregroundColor = keywordColor(line.text)
            return a
        }
        var out = AttributedString()
        for r in line.runs {
            var a = AttributedString(r.text)
            let st = r.style
            var fg = st.fg.map(color) ?? defaultFG
            var bg = st.bg.map(color)
            if st.inverse { let f = fg; fg = bg ?? .black; bg = f }
            if st.bold && st.fg == nil { fg = .white }
            a.foregroundColor = st.dim ? fg.opacity(0.6) : fg
            if let bg { a.backgroundColor = bg }
            if st.underline { a.underlineStyle = .single }
            if st.bold || st.italic {
                var f = Font.system(size: TerminalLines.fontSize, design: .monospaced)
                if st.bold { f = f.bold() }
                if st.italic { f = f.italic() }
                a.font = f
            }
            out.append(a)
        }
        return out
    }

    private static func keywordColor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") || l.contains("fatal") { return NotchTheme.danger }
        if l.contains("warning") || l.contains("warn ") { return NotchTheme.warning }
        return defaultFG
    }
}

/// Invisible first responder that turns key presses into terminal input for the running command.
private struct TerminalKeyCatcher: NSViewRepresentable {
    @Binding var focused: Bool
    let send: (String) -> Void
    /// Bumped by a click on the terminal to (re)take focus.
    @MainActor static var focusRequest = 0 { didSet { NotificationCenter.default.post(name: .terminalFocusRequest, object: nil) } }

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.send = send
        v.onFocus = { f in
            DispatchQueue.main.async {
                focused = f
                NotchCoordinator.shared.setKeyboardHold(f)
            }
        }
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) { v.send = send }

    final class KeyView: NSView {
        var send: ((String) -> Void)?
        var onFocus: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { onFocus?(false); return }
            observers.append(NotificationCenter.default.addObserver(forName: .terminalFocusRequest, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeFocus() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocus?(false) }
            })
            // Already typing in the notch (e.g. clicked Run): keep the keyboard here.
            if window.isKeyWindow { DispatchQueue.main.async { self.takeFocus() } }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        private func takeFocus() {
            guard let window else { return }
            if let panel = window as? NotchPanel { panel.allowsKey = true }
            window.makeKey()
            if window.makeFirstResponder(self) { onFocus?(true) }
        }

        override func resignFirstResponder() -> Bool { onFocus?(false); return true }

        override func keyDown(with e: NSEvent) {
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) {
                if e.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) { send?(s); return }
                super.keyDown(with: e)
                return
            }
            let seq: String?
            switch e.keyCode {
            case 36, 76: seq = "\r"
            case 51: seq = "\u{7F}"
            case 117: seq = "\u{1B}[3~"
            case 53: seq = "\u{1B}"
            case 48: seq = flags.contains(.shift) ? "\u{1B}[Z" : "\t"
            case 123: seq = "\u{1B}[D"
            case 124: seq = "\u{1B}[C"
            case 125: seq = "\u{1B}[B"
            case 126: seq = "\u{1B}[A"
            case 115: seq = "\u{1B}[H"
            case 119: seq = "\u{1B}[F"
            case 116: seq = "\u{1B}[5~"
            case 121: seq = "\u{1B}[6~"
            default: seq = e.characters
            }
            if let seq, !seq.isEmpty { send?(seq) }
        }
    }
}

extension Notification.Name {
    static let terminalFocusRequest = Notification.Name("NotchDeckTerminalFocusRequest")
}

/// Reopens the output of any command that has run this session (also after "back" or a collapse).
struct OutputMenu: View {
    let module: MetroModule
    var fill = false

    var body: some View {
        let items = module.commands.filter { c in
            module.runner.run(for: c.id).map { $0.state != .idle || !$0.allLines.isEmpty } ?? false
        }
        if items.count == 1, let only = items.first {
            DevIconButton(symbol: "terminal", help: "Show output: \(only.name)", minWidth: 26) { module.showTerminal(only) }
        } else {
            Menu {
                ForEach(items) { c in
                    Button { module.showTerminal(c) } label: {
                        Label(title(for: c), systemImage: symbol(for: c))
                    }
                }
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(items.isEmpty ? NotchTheme.tertiaryText : .white)
                    .frame(minWidth: 26, maxWidth: fill ? .infinity : 26, minHeight: 24, maxHeight: 24)
                    .background(Capsule().fill(NotchTheme.surface))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .disabled(items.isEmpty)
            .help(items.isEmpty ? "No output yet \u{2014} run a command first" : "Show output")
        }
    }

    private func title(for c: DevCommand) -> String {
        switch module.runner.state(for: c.id) {
        case .running: return "\(c.name) \u{2014} running"
        case .succeeded(let d): return "\(c.name) \u{2014} done \(devClock(d))"
        case .failed(let code, _, _): return "\(c.name) \u{2014} failed (\(code))"
        case .idle: return c.name
        }
    }

    private func symbol(for c: DevCommand) -> String {
        switch module.runner.state(for: c.id) {
        case .running: return "play.circle"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .idle: return c.symbol
        }
    }
}
