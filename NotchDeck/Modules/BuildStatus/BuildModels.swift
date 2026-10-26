import Foundation
import SwiftUI

enum BuildSource: String, Codable {
    case xcode, cli, gradle

    var glyph: String {
        switch self {
        case .xcode: return "hammer.fill"
        case .cli: return "terminal.fill"
        case .gradle: return "a.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .xcode: return "Xcode"
        case .cli: return "Terminal"
        case .gradle: return "Gradle"
        }
    }

    var tint: Color {
        switch self {
        case .xcode: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .cli: return Color.white.opacity(0.85)
        case .gradle: return Color(red: 0.40, green: 0.85, blue: 0.55)
        }
    }
}

enum BuildStatus: Equatable {
    case running, succeeded, warnings, failed
}

struct BuildRecord: Identifiable, Equatable {
    var id: String
    var source: BuildSource
    var project: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: BuildStatus = .running
    var errors = 0
    var warnings = 0
    var message: String?
    var logTail: String?
    var cwd: String?
    var pid: Int32?
    /// False when only a finish record was seen (e.g. Gradle configuration-cache hit).
    var hasStart = true
    /// Gradle: tasks finished so far (from progress records).
    var tasksDone: Int?

    var isRunning: Bool { status == .running }
    var isFailed: Bool { status == .failed }

    var duration: TimeInterval? {
        guard let endedAt, hasStart else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Key used to compute per-project average durations.
    var historyKey: String {
        source == .xcode ? "xcode|\(project)" : "\(source.rawValue)|\(project)|\(title)"
    }
}

// MARK: - Spool wire format

struct SpoolRecord: Decodable {
    var v: Int?
    var id: String
    var startId: String?
    var kind: String
    var source: String?
    var project: String?
    var title: String?
    var cwd: String?
    var pid: Int32?
    var startedAt: Double?
    var endedAt: Double?
    var exit: Int?
    var tail: String?
    var message: String?
    var errors: Int?
    var warnings: Int?
    var tasks: String?
    /// Gradle progress records: finished task count so far (`last` = final count).
    var done: Int?
    var last: Bool?

    var key: String { startId ?? id }
}

func buildDuration(_ t: TimeInterval) -> String {
    if t < 10 { return String(format: "%.1fs", t) }
    let s = Int(t.rounded())
    if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
    if s >= 60 { return String(format: "%dm %02ds", s / 60, s % 60) }
    return "\(s)s"
}
