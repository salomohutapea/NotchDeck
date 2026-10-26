import Foundation

// Pure timer engine (Foundation only). Every mutation takes `now`, so it is testable
// and exact across sleep/wake: the running state stores an absolute end date.

enum FocusPhase: String, Codable {
    case focus, shortBreak, longBreak
    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
    var isBreak: Bool { self != .focus }
}

struct FocusConfig: Codable, Equatable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var sessionsBeforeLongBreak = 4
    var autoStartBreaks = true
    var autoStartFocus = false

    func duration(of phase: FocusPhase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(max(1, focusMinutes) * 60)
        case .shortBreak: return TimeInterval(max(1, shortBreakMinutes) * 60)
        case .longBreak: return TimeInterval(max(1, longBreakMinutes) * 60)
        }
    }
}

enum FocusRunState: Codable, Equatable {
    case idle
    case running(phase: FocusPhase, endsAt: Date)
    case paused(phase: FocusPhase, remaining: TimeInterval)
}

struct FocusStats: Codable, Equatable {
    var dayKey = ""
    var sessions = 0
    var focusSeconds: TimeInterval = 0
    var streak = 0
    var lastSessionDayKey = ""
}

enum FocusEvent: Equatable {
    case phaseEnded(finished: FocusPhase, next: FocusPhase, autoStarted: Bool)
}

struct PomodoroEngine: Codable, Equatable {
    var config = FocusConfig()
    var state: FocusRunState = .idle
    /// Phase shown/started next while idle.
    var idlePhase: FocusPhase = .focus
    /// Focus sessions completed since the last long break.
    var completedInCycle = 0
    /// Planned length of the current phase (includes +5 extensions).
    var phaseTotal: TimeInterval = 25 * 60
    var stats = FocusStats()

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Derived

    var phase: FocusPhase {
        switch state {
        case .idle: return idlePhase
        case .running(let p, _), .paused(let p, _): return p
        }
    }
    var isRunning: Bool { if case .running = state { return true }; return false }
    var isPaused: Bool { if case .paused = state { return true }; return false }
    var isIdle: Bool { if case .idle = state { return true }; return false }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return config.duration(of: idlePhase)
        case .running(_, let end): return max(0, end.timeIntervalSince(now))
        case .paused(_, let r): return r
        }
    }

    func progress(at now: Date) -> Double {
        guard phaseTotal > 0 else { return 0 }
        if isIdle { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / phaseTotal))
    }

    func todaySessions(at now: Date, calendar: Calendar = .current) -> Int {
        stats.dayKey == Self.dayKey(now, calendar: calendar) ? stats.sessions : 0
    }
    func todayFocusMinutes(at now: Date, calendar: Calendar = .current) -> Int {
        stats.dayKey == Self.dayKey(now, calendar: calendar) ? Int((stats.focusSeconds / 60).rounded()) : 0
    }
    func streak(at now: Date, calendar: Calendar = .current) -> Int {
        let today = Self.dayKey(now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { Self.dayKey($0, calendar: calendar) } ?? ""
        return (stats.lastSessionDayKey == today || stats.lastSessionDayKey == yesterday) ? stats.streak : 0
    }

    // MARK: Actions

    mutating func start(now: Date, phase: FocusPhase? = nil) {
        let p = phase ?? idlePhase
        let d = config.duration(of: p)
        idlePhase = p
        phaseTotal = d
        state = .running(phase: p, endsAt: now.addingTimeInterval(d))
    }

    mutating func pause(now: Date) {
        if case .running(let p, let end) = state {
            state = .paused(phase: p, remaining: max(0, end.timeIntervalSince(now)))
        }
    }

    mutating func resume(now: Date) {
        if case .paused(let p, let r) = state {
            state = .running(phase: p, endsAt: now.addingTimeInterval(r))
        }
    }

    mutating func toggle(now: Date) {
        switch state {
        case .idle: start(now: now)
        case .running: pause(now: now)
        case .paused: resume(now: now)
        }
    }

    mutating func addMinutes(_ m: Int, now: Date) {
        let s = TimeInterval(m * 60)
        switch state {
        case .running(let p, let end): state = .running(phase: p, endsAt: end.addingTimeInterval(s)); phaseTotal += s
        case .paused(let p, let r): state = .paused(phase: p, remaining: r + s); phaseTotal += s
        case .idle: break
        }
    }

    /// Phase that follows `finished` given the cycle counter (already updated).
    private func nextPhase(after finished: FocusPhase) -> FocusPhase {
        switch finished {
        case .focus: return completedInCycle >= max(1, config.sessionsBeforeLongBreak) ? .longBreak : .shortBreak
        case .shortBreak, .longBreak: return .focus
        }
    }

    /// Skip to next phase without credit.
    mutating func skip(now: Date) {
        let cur = phase
        if cur == .longBreak { completedInCycle = 0 }
        let next = nextPhase(after: cur)
        enter(next, autoStart: !isIdle && autoStarts(next), now: now)
    }

    mutating func reset(now: Date) {
        state = .idle
        idlePhase = .focus
        completedInCycle = 0
        phaseTotal = config.duration(of: .focus)
    }

    /// Set a focus duration preset and start a focus session immediately.
    mutating func startPreset(minutes: Int, now: Date) {
        config.focusMinutes = minutes
        start(now: now, phase: .focus)
    }

    /// Call periodically and on wake. Returns events for side effects.
    @discardableResult
    mutating func tick(now: Date, calendar: Calendar = .current) -> [FocusEvent] {
        rollDay(now: now, calendar: calendar)
        guard case .running(let p, let end) = state, now >= end else { return [] }
        if p == .focus {
            completedInCycle += 1
            recordSession(seconds: phaseTotal, now: now, calendar: calendar)
        } else if p == .longBreak {
            completedInCycle = 0
        }
        let next = nextPhase(after: p)
        let auto = autoStarts(next)
        enter(next, autoStart: auto, now: now)
        return [.phaseEnded(finished: p, next: next, autoStarted: auto)]
    }

    mutating func resetTodayStats() {
        stats.dayKey = ""; stats.sessions = 0; stats.focusSeconds = 0
    }

    // MARK: Internals

    private func autoStarts(_ p: FocusPhase) -> Bool { p == .focus ? config.autoStartFocus : config.autoStartBreaks }

    private mutating func enter(_ p: FocusPhase, autoStart: Bool, now: Date) {
        idlePhase = p
        phaseTotal = config.duration(of: p)
        state = autoStart ? .running(phase: p, endsAt: now.addingTimeInterval(phaseTotal)) : .idle
    }

    private mutating func rollDay(now: Date, calendar: Calendar) {
        let key = Self.dayKey(now, calendar: calendar)
        if stats.dayKey != key { stats.dayKey = key; stats.sessions = 0; stats.focusSeconds = 0 }
    }

    private mutating func recordSession(seconds: TimeInterval, now: Date, calendar: Calendar) {
        rollDay(now: now, calendar: calendar)
        stats.sessions += 1
        stats.focusSeconds += seconds
        let today = stats.dayKey
        if stats.lastSessionDayKey != today {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { Self.dayKey($0, calendar: calendar) } ?? ""
            stats.streak = stats.lastSessionDayKey == yesterday ? stats.streak + 1 : 1
            stats.lastSessionDayKey = today
        }
    }
}
