import SwiftUI

let focusTomato = Color(red: 1.0, green: 0.38, blue: 0.30)
let focusGreen = NotchTheme.success

extension FocusPhase {
    var color: Color { isBreak ? focusGreen : focusTomato }
    var glyph: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "leaf.fill"
        }
    }
}

func formatClock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct FocusRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 2
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct FocusCompactLeading: View {
    let module: PomodoroModule
    var body: some View {
        let e = module.engine
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            ZStack {
                FocusRing(progress: e.progress(at: tl.date), color: e.phase.color, lineWidth: 2.2)
                Image(systemName: e.phase.glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(e.phase.color)
            }
            .frame(width: 20, height: 20)
            .opacity(e.isPaused ? 0.6 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct FocusCompactTrailing: View {
    let module: PomodoroModule
    var body: some View {
        let e = module.engine
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            Text(formatClock(e.remaining(at: tl.date)))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(e.isPaused ? NotchTheme.secondaryText : .white)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct FocusExpandedView: View {
    @Bindable var module: PomodoroModule

    var body: some View {
        let e = module.engine
        HStack(spacing: 18) {
            ring(e)
            VStack(alignment: .leading, spacing: 9) {
                TextField("What are you focusing on?", text: $module.label)
                    .textFieldStyle(.plain)
                    .font(NotchTheme.bodyFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                controls(e)
                HStack(spacing: 6) {
                    ForEach([15, 25, 50], id: \.self) { m in
                        Button { module.startPreset(m) } label: {
                            Text("\(m)m").font(NotchTheme.captionFont)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(e.config.focusMinutes == m ? focusTomato.opacity(0.35) : NotchTheme.surface, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    dots(e)
                }
                stats(e)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ring(_ e: PomodoroEngine) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            ZStack {
                FocusRing(progress: e.progress(at: tl.date), color: e.phase.color, lineWidth: 6)
                VStack(spacing: 2) {
                    Text(formatClock(e.remaining(at: tl.date)))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Text(e.phase.title + (e.isPaused ? " · paused" : ""))
                        .font(NotchTheme.captionFont)
                        .foregroundStyle(e.phase.color)
                }
            }
        }
        .frame(width: 126, height: 126)
    }

    private func controls(_ e: PomodoroEngine) -> some View {
        HStack(spacing: 8) {
            Button { module.toggle() } label: {
                Label(e.isRunning ? "Pause" : (e.isPaused ? "Resume" : "Start"),
                      systemImage: e.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(e.phase.color.opacity(0.85), in: Capsule())
            }.buttonStyle(.plain)
            iconButton("forward.end.fill", help: "Skip to next phase") { module.skip() }
            iconButton("arrow.counterclockwise", help: "Reset") { module.reset() }
            Button { module.addFive() } label: {
                Text("+5").font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(NotchTheme.surface, in: Capsule())
            }.buttonStyle(.plain).disabled(e.isIdle).opacity(e.isIdle ? 0.4 : 1).help("Add 5 minutes")
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(NotchTheme.surface, in: Capsule())
        }.buttonStyle(.plain).help(help)
    }

    private func dots(_ e: PomodoroEngine) -> some View {
        let n = max(1, e.config.sessionsBeforeLongBreak)
        let filled = e.phase == .longBreak ? n : min(n, e.completedInCycle)
        return HStack(spacing: 4) {
            ForEach(0..<n, id: \.self) { i in
                Circle().fill(i < filled ? focusTomato : Color.white.opacity(0.2)).frame(width: 7, height: 7)
            }
        }
    }

    private func stats(_ e: PomodoroEngine) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { tl in
            let n = e.todaySessions(at: tl.date), m = e.todayFocusMinutes(at: tl.date), s = e.streak(at: tl.date)
            Text("Today: \(n) session\(n == 1 ? "" : "s") · \(m) min" + (s > 0 ? " · \(s)-day streak" : ""))
                .font(NotchTheme.captionFont)
                .foregroundStyle(NotchTheme.secondaryText)
        }
    }
}

struct FocusSettingsView: View {
    let module: PomodoroModule
    @AppStorage(PomodoroModule.Keys.sound) private var sound = "Glass"
    @AppStorage(PomodoroModule.Keys.mute) private var mute = false
    @AppStorage(PomodoroModule.Keys.notify) private var notify = true
    @AppStorage(PomodoroModule.Keys.hotkey) private var hotkey = false

    private func bind<T>(_ kp: WritableKeyPath<FocusConfig, T>) -> Binding<T> {
        Binding(get: { module.engine.config[keyPath: kp] },
                set: { v in module.updateConfig { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Section("Focus") {
            Stepper("Focus: \(module.engine.config.focusMinutes) min", value: bind(\.focusMinutes), in: 1...180)
            Stepper("Short break: \(module.engine.config.shortBreakMinutes) min", value: bind(\.shortBreakMinutes), in: 1...60)
            Stepper("Long break: \(module.engine.config.longBreakMinutes) min", value: bind(\.longBreakMinutes), in: 1...90)
            Stepper("Sessions before long break: \(module.engine.config.sessionsBeforeLongBreak)",
                    value: bind(\.sessionsBeforeLongBreak), in: 1...12)
            Toggle("Auto-start breaks", isOn: bind(\.autoStartBreaks))
            Toggle("Auto-start focus sessions", isOn: bind(\.autoStartFocus))
            Picker("Sound", selection: $sound) {
                ForEach(PomodoroModule.sounds, id: \.self) { Text($0).tag($0) }
            }
            .disabled(mute)
            .onChange(of: sound) { _, new in if !mute { NSSound(named: NSSound.Name(new))?.play() } }
            Toggle("Mute sound", isOn: $mute)
            Toggle("Send notification when a phase ends", isOn: $notify)
            Toggle("Global shortcut ⌃⌥P to start/pause", isOn: $hotkey)
                .onChange(of: hotkey) { _, _ in module.updateHotkey() }
            Button("Reset today's stats") { module.resetTodayStats() }
        }
    }
}

// MARK: - Compact peek row

struct FocusPeekRow: View {
    let engine: PomodoroEngine

    var body: some View {
        let phase = engine.phase
        let text: String = phase.isBreak
            ? "Focus done \u{2014} take a \(Int(engine.config.duration(of: phase) / 60)) min break"
            : "Break over"
        HStack(spacing: 8) {
            Image(systemName: phase.glyph)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phase.color)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryText)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}
