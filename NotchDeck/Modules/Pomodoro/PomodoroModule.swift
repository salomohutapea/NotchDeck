import SwiftUI
import Observation
import AppKit
import UserNotifications

@MainActor @Observable
final class PomodoroModule: NotchModule {
    let id: ModuleID = .pomodoro
    var isLive = false
    var compactPriority = 0

    private(set) var engine: PomodoroEngine
    var label: String {
        didSet { UserDefaults.standard.set(label, forKey: Keys.label) }
    }

    enum Keys {
        static let engine = "pomodoro.engine"
        static let label = "pomodoro.label"
        static let sound = "pomodoro.sound"
        static let mute = "pomodoro.mute"
        static let notify = "pomodoro.notify"
        static let hotkey = "pomodoro.hotkey"
    }
    static let sounds = ["Glass", "Hero", "Ping", "Submarine", "Funk", "Purr", "Tink"]

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.engine), let e = try? JSONDecoder().decode(PomodoroEngine.self, from: data) {
            engine = e
        } else {
            engine = PomodoroEngine()
        }
        label = d.string(forKey: Keys.label) ?? ""
        refreshLive()
    }

    // MARK: Lifecycle

    func start() {
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        tick()
        updateHotkey()
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        updateHotkey()
    }

    // MARK: Actions

    func toggle() {
        if engine.isIdle { requestNotificationAuthIfNeeded() }
        mutate { $0.toggle(now: Date()) }
    }
    func skip() { mutate { $0.skip(now: Date()) } }
    func reset() { mutate { $0.reset(now: Date()) } }
    func addFive() { mutate { $0.addMinutes(5, now: Date()) } }
    func startPreset(_ minutes: Int) {
        requestNotificationAuthIfNeeded()
        mutate { $0.startPreset(minutes: minutes, now: Date()) }
    }
    func resetTodayStats() { mutate { $0.resetTodayStats() } }
    func updateConfig(_ change: (inout FocusConfig) -> Void) {
        mutate { e in
            change(&e.config)
            if e.isIdle { e.phaseTotal = e.config.duration(of: e.idlePhase) }
        }
    }

    private func mutate(_ change: (inout PomodoroEngine) -> Void) {
        change(&engine)
        persist()
        refreshLive()
        scheduleTimer()
    }

    private func tick() {
        let events = engine.tick(now: Date())
        persist()
        refreshLive()
        scheduleTimer()
        for case .phaseEnded(let finished, let next, _) in events { phaseEnded(finished: finished, next: next) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(engine) { UserDefaults.standard.set(data, forKey: Keys.engine) }
    }

    private func refreshLive() {
        isLive = !engine.isIdle
        compactPriority = engine.isRunning ? 60 : (engine.isPaused ? 30 : 0)
    }

    private func scheduleTimer() {
        timer?.invalidate(); timer = nil
        guard started, engine.isRunning else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Phase end side effects

    private func phaseEnded(finished: FocusPhase, next: FocusPhase) {
        let d = UserDefaults.standard
        NotchCoordinator.shared.peek(.pomodoro, duration: 6)
        if !d.bool(forKey: Keys.mute) {
            NSSound(named: NSSound.Name(d.string(forKey: Keys.sound) ?? "Glass"))?.play()
        }
        if d.object(forKey: Keys.notify) as? Bool ?? true {
            let content = UNMutableNotificationContent()
            content.title = finished == .focus ? "Focus session complete" : "\(finished.title) over"
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            content.body = finished == .focus
                ? "Time for a \(next.title.lowercased())." + (trimmed.isEmpty ? "" : " (\(trimmed))")
                : "Ready for the next focus session."
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    private func requestNotificationAuthIfNeeded() {
        guard UserDefaults.standard.object(forKey: Keys.notify) as? Bool ?? true else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func updateHotkey() {
        let enabled = started && UserDefaults.standard.bool(forKey: Keys.hotkey)
        if enabled {
            HotkeyCenter.shared.register(id: "pomodoro.toggle", keyCode: 35, modifiers: [.control, .option]) { [weak self] in
                self?.toggle()
            }
        } else {
            HotkeyCenter.shared.unregister(id: "pomodoro.toggle")
        }
    }

    // MARK: Views

    func compactLeading() -> AnyView { AnyView(FocusCompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(FocusCompactTrailing(module: self)) }
    func expanded() -> AnyView { AnyView(FocusExpandedView(module: self)) }
    func settings() -> AnyView? { AnyView(FocusSettingsView(module: self)) }
    func peekContent() -> AnyView? { AnyView(FocusPeekRow(engine: engine)) }
}
