import Foundation

enum ModuleID: String, CaseIterable, Codable, Identifiable {
    case dashboard, system, nowPlaying, musicLyrics, aiStatus, metro, buildStatus, fileShelf, clipboard, pomodoro
    var id: String { rawValue }

    /// Collapsed-notch icon priority (lower = closer to the notch): music, AI, builds, then the rest.
    var compactRank: Int {
        switch self {
        case .nowPlaying: return 10
        case .musicLyrics: return 11
        case .aiStatus: return 20
        case .buildStatus: return 30
        default: return 50
        }
    }

    /// Modules that shipped before `knownModules` was tracked.
    static let legacyCases: [ModuleID] = [.nowPlaying, .musicLyrics, .aiStatus, .metro]

    var title: String {
        switch self {
        case .dashboard: return "Home"
        case .system: return "System"
        case .nowPlaying: return "Now Playing"
        case .musicLyrics: return "Music & Lyrics"
        case .aiStatus: return "AI Agents"
        case .metro: return "Devtools"
        case .buildStatus: return "Builds"
        case .fileShelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .pomodoro: return "Focus"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .system: return "bolt.circle.fill"
        case .nowPlaying: return "play.circle.fill"
        case .musicLyrics: return "quote.bubble.fill"
        case .aiStatus: return "sparkles"
        case .metro: return "wrench.and.screwdriver.fill"
        case .buildStatus: return "hammer.fill"
        case .fileShelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .pomodoro: return "timer"
        }
    }
}
