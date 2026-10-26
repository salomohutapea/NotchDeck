import SwiftUI

// MARK: - Collapsed

struct MetroCompactLeading: View {
    let module: MetroModule
    var body: some View {
        let s = module.primary
        let bundling = s?.isBundling ?? false
        let task = module.runningLongTask
        Group {
            if !bundling, let task {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    Image(systemName: task.cmd.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(devCyan)
                        .opacity(0.65 + 0.35 * sin(tl.date.timeIntervalSinceReferenceDate * 4))
                }
            } else if !bundling, module.taskResultVisible, let r = module.taskResult {
                Image(systemName: r.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(r.ok ? NotchTheme.success : NotchTheme.danger)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !bundling)) { tl in
                    Image(systemName: "atom")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(s?.phase == .failed && s?.resultVisible == true ? NotchTheme.danger : devCyan)
                        .rotationEffect(.degrees(bundling ? (tl.date.timeIntervalSinceReferenceDate * 180).truncatingRemainder(dividingBy: 360) : 0))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct MetroCompactTrailing: View {
    let module: MetroModule
    var body: some View {
        let s = module.primary
        Group {
            if let s, s.isBundling {
                HStack(spacing: 5) {
                    ProgressRing(progress: s.progress, color: devCyan).frame(width: 14, height: 14)
                    Text("\(Int(s.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            } else if let task = module.runningLongTask {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(devClock(tl.date.timeIntervalSince(task.since)))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            } else if module.taskResultVisible, let r = module.taskResult {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(r.ok ? NotchTheme.success : NotchTheme.danger)
            } else if let s, s.resultVisible {
                Image(systemName: s.phase == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(s.phase == .failed ? NotchTheme.danger : NotchTheme.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Compact peek rows

struct MetroPeekRow: View {
    let service: MetroService

    var body: some View {
        let failed = service.phase == .failed
        HStack(spacing: 8) {
            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(failed ? NotchTheme.danger : NotchTheme.success)
                .frame(width: 20)
            if failed {
                Text("Bundle failed")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1).fixedSize()
                Text(Self.firstLine(service.errorMessage))
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.secondaryText)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                let d = service.lastDuration.map { " \u{00B7} " + formatDuration($0) } ?? ""
                Text("Bundle ready" + d)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private static func firstLine(_ s: String?) -> String {
        (s ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

struct DevtoolsTaskPeekRow: View {
    let result: MetroModule.TaskResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(result.ok ? NotchTheme.success : NotchTheme.danger)
                .frame(width: 20)
            if result.ok {
                Text("\(result.name) \u{00B7} \(devClock(result.duration))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1)
            } else {
                Text("\(result.name) failed")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1).fixedSize()
                if let m = result.message {
                    Text(m).font(.system(size: 12)).foregroundStyle(NotchTheme.secondaryText)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Settings

struct MetroSettingsView: View {
    @Bindable var module: MetroModule
    @State private var newPort = ""
    @State private var expandedID: String?

    var body: some View {
        Section("Devtools") {
            Toggle("Peek when a bundle or task finishes", isOn: $module.peekOnFinish)
            ForEach(module.ports, id: \.self) { port in
                HStack {
                    Text("Also watch localhost:" + String(port)).monospacedDigit()
                    Spacer()
                    Button(role: .destructive) {
                        module.ports.removeAll { $0 == port }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Watch another port", text: $newPort).onSubmit(addPort)
                Button("Add", action: addPort).disabled(Int(newPort) == nil)
            }
            Text("Each Dev server command is watched on its own port, so you can run several at once (e.g. a second one with `--port 8082`). Extra ports here are for servers started elsewhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Commands") {
            // Id-based bindings: index-based `ForEach($array)` bindings trap when a row is removed.
            ForEach(module.commands) { c in
                commandRow(binding(for: c.id))
            }
            HStack {
                Button("Add command") {
                    let c = DevCommand.blank()
                    module.commands.append(c)
                    expandedID = c.id
                }
                Spacer()
                Button("Restore defaults", role: .destructive) { module.commands = DevCommand.defaults; expandedID = nil }
            }
            Text("Commands run through your login shell (zsh -ilc) in a pseudo-terminal, so nvm and aliases work. Logs: ~/Library/Application Support/NotchDeck/logs")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(for id: String) -> Binding<DevCommand> {
        Binding(
            get: { module.commands.first { $0.id == id } ?? DevCommand.blank() },
            set: { new in
                if let i = module.commands.firstIndex(where: { $0.id == id }) { module.commands[i] = new }
            })
    }

    @ViewBuilder
    private func commandRow(_ cmd: Binding<DevCommand>) -> some View {
        let id = cmd.wrappedValue.id
        let idx = module.commands.firstIndex { $0.id == id } ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: cmd.wrappedValue.symbol).frame(width: 18)
                Text(cmd.wrappedValue.name).fontWeight(.medium)
                Text(cmd.wrappedValue.kind.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { move(idx, -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(idx == 0)
                Button { move(idx, 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(idx >= module.commands.count - 1)
                Button(expandedID == id ? "Done" : "Edit") { expandedID = expandedID == id ? nil : id }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) {
                    if expandedID == id { expandedID = nil }
                    module.commands.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless)
            }
            if expandedID == id {
                TextField("Name", text: cmd.name)
                HStack {
                    TextField("SF Symbol", text: cmd.symbol)
                    Image(systemName: cmd.wrappedValue.symbol)
                }
                TextField("Command", text: cmd.command).font(.system(.body, design: .monospaced))
                TextField("Working directory", text: cmd.cwd)
                Picker("Kind", selection: cmd.kind) {
                    ForEach(DevCommandKind.allCases) { Text($0.label).tag($0) }
                }
                if cmd.wrappedValue.kind == .devServer {
                    TextField("Port", text: Binding(
                        get: { cmd.wrappedValue.port.map(String.init) ?? "" },
                        set: { cmd.wrappedValue.port = Int($0.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }),
                        prompt: Text("\(cmd.wrappedValue.serverPort) (from --port, else 8081)"))
                }
                Toggle("Track as build (show in Builds)", isOn: cmd.trackAsBuild)
                Toggle("Open in Terminal instead", isOn: cmd.openInTerminal)
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard module.commands.indices.contains(i), module.commands.indices.contains(j) else { return }
        module.commands.swapAt(i, j)
    }

    private func addPort() {
        guard let p = Int(newPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return }
        if !module.ports.contains(p) { module.ports.append(p) }
        newPort = ""
    }
}
