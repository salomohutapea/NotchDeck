import Foundation

enum DevCommandKind: String, Codable, CaseIterable, Identifiable {
    /// Long-running server (e.g. `npx react-native start`). Gets reload/menu/key forwarding when we own the pty.
    case devServer
    /// Finite command; shows running / succeeded / failed state.
    case task
    /// Fire-and-forget (`open -a ...`).
    case launcher

    var id: String { rawValue }
    var label: String {
        switch self {
        case .devServer: return "Dev server"
        case .task: return "Task"
        case .launcher: return "Launcher"
        }
    }
}

struct DevCommand: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var command: String
    var cwd: String
    var kind: DevCommandKind
    /// Writes BuildStatus spool records so the Builds module shows it.
    var trackAsBuild: Bool = false
    /// Run in Terminal.app via AppleScript instead of an owned pty.
    var openInTerminal: Bool = false
    /// Dev servers only: port to watch. nil = `--port N` from the command, else 8081.
    var port: Int? = nil

    var serverPort: Int {
        if let port { return port }
        let parts = command.split(whereSeparator: { $0 == " " || $0 == "=" }).map(String.init)
        if let i = parts.firstIndex(where: { $0 == "--port" || $0 == "-p" }), i + 1 < parts.count,
           let p = Int(parts[i + 1]), (1...65535).contains(p) { return p }
        return 8081
    }

    var expandedCwd: String {
        let c = cwd.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? NSHomeDirectory() : (c as NSString).expandingTildeInPath
    }

    static func blank() -> DevCommand {
        DevCommand(id: UUID().uuidString, name: "New command", symbol: "terminal", command: "", cwd: "~", kind: .task)
    }

    /// Generic starters; edit them in Settings > Devtools (your own list is stored locally in preferences).
    static let defaults: [DevCommand] = [
        DevCommand(id: "dev-server", name: "Dev server", symbol: "bolt.horizontal.fill",
                   command: "npx react-native start", cwd: "~", kind: .devServer),
        DevCommand(id: "adb-reverse", name: "adb 8081", symbol: "arrow.left.arrow.right",
                   command: "adb reverse tcp:8081 tcp:8081", cwd: "~", kind: .task),
        DevCommand(id: "android-studio", name: "Android Studio", symbol: "a.square.fill",
                   command: "open -a \"Android Studio\"", cwd: "~", kind: .launcher),
    ]

    static let defaultsKey = "metro.commands"

    /// Default command ids already offered to this user; defaults added in later versions get merged in once.
    private static let seenKey = "metro.seenDefaultIDs"

    static func load() -> [DevCommand] {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: defaultsKey), var list = try? JSONDecoder().decode([DevCommand].self, from: data) else {
            d.set(defaults.map(\.id), forKey: seenKey)
            return defaults
        }
        // Lists saved before this key existed already had the first defaults.
        var seen = Set((d.array(forKey: seenKey) as? [String]) ?? ["dev-server", "android-studio"])
        // Renamed default (only if the user hasn't customised the old name).
        if let i = list.firstIndex(where: { $0.id == "adb-reverse" && $0.name == "ADB reverse 8081" }) {
            list[i].name = "adb 8081"
            save(list)
        }
        let fresh = defaults.filter { !seen.contains($0.id) }
        if !fresh.isEmpty {
            for c in fresh {
                let at = list.firstIndex { $0.id == "android-studio" } ?? list.endIndex
                list.insert(c, at: at)
                seen.insert(c.id)
            }
            save(list)
        }
        d.set(Array(seen), forKey: seenKey)
        return list
    }

    static func save(_ list: [DevCommand]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

func devClock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
