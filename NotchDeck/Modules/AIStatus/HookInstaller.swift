import Foundation

/// Installs / removes NotchDeck hook entries in Claude Code and Codex config files.
/// All paths are injectable so the logic can be tested against temp files.
struct HookInstaller {
    enum Target: String, CaseIterable {
        case claude, codex
        var displayName: String { self == .claude ? "Claude Code" : "Codex" }
        var events: [String] {
            switch self {
            case .claude: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd"]
            case .codex: return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
            }
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let scriptName = "notchdeck-hook.sh"

    var claudeSettings: URL
    var codexHooks: URL
    var scriptDestination: URL
    var scriptSource: URL?

    static func standard() -> HookInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return HookInstaller(
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            codexHooks: home.appendingPathComponent(".codex/hooks.json"),
            scriptDestination: home.appendingPathComponent("Library/Application Support/NotchDeck/\(scriptName)"),
            scriptSource: Bundle.main.url(forResource: "notchdeck-hook", withExtension: "sh"))
    }

    func configURL(_ t: Target) -> URL { t == .claude ? claudeSettings : codexHooks }
    func command(for t: Target) -> String { "\"\(scriptDestination.path)\" \(t.rawValue)" }

    // MARK: Status

    func isInstalled(_ t: Target) -> Bool {
        guard let root = try? readJSON(configURL(t)),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, v) in hooks {
            for group in (v as? [[String: Any]]) ?? [] {
                for h in (group["hooks"] as? [[String: Any]]) ?? [] where Self.isOurs(h) { return true }
            }
        }
        return false
    }

    private static func isOurs(_ h: [String: Any]) -> Bool {
        ((h["command"] as? String) ?? "").contains(scriptName)
    }

    // MARK: Install / uninstall

    func install(_ t: Target) throws {
        try installScript()
        let url = configURL(t)
        var root = try readJSON(url)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let cmd = command(for: t)
        for event in t.events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            var found = false
            for gi in groups.indices {
                var hs = (groups[gi]["hooks"] as? [[String: Any]]) ?? []
                for hi in hs.indices where Self.isOurs(hs[hi]) {
                    found = true
                    hs[hi]["type"] = "command"
                    hs[hi]["command"] = cmd
                }
                if found { groups[gi]["hooks"] = hs }
            }
            if !found {
                var group: [String: Any] = ["hooks": [["type": "command", "command": cmd]]]
                if t == .claude, event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeIfChanged(root, to: url)
    }

    func uninstall(_ t: Target) throws {
        let url = configURL(t)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try readJSON(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, v) in hooks {
            guard var groups = v as? [[String: Any]] else { continue }
            var touched = false
            for gi in groups.indices.reversed() {
                guard var hs = groups[gi]["hooks"] as? [[String: Any]] else { continue }
                let before = hs.count
                hs.removeAll(where: Self.isOurs)
                guard hs.count != before else { continue }
                touched = true
                if hs.isEmpty { groups.remove(at: gi) } else { groups[gi]["hooks"] = hs }
            }
            guard touched else { continue }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeIfChanged(root, to: url)
    }

    // MARK: Helpers

    private func installScript() throws {
        let fm = FileManager.default
        guard let src = scriptSource, fm.fileExists(atPath: src.path) else {
            throw InstallError(message: "Hook script not found in app bundle")
        }
        try fm.createDirectory(at: scriptDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: src)
        try data.write(to: scriptDestination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptDestination.path)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError(message: "\(url.lastPathComponent) is not a valid JSON object; left untouched")
        }
        return obj
    }

    private func writeIfChanged(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let existing = try? Data(contentsOf: url)
        if let existing,
           let a = try? JSONSerialization.jsonObject(with: existing) as? NSDictionary,
           a.isEqual(to: root) { return } // semantically identical: no write, no backup
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existing != nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            var backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".notchdeck-backup-" + stamp)
            var n = 2
            while fm.fileExists(atPath: backup.path) { // never overwrite an earlier backup
                backup = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".notchdeck-backup-" + stamp + "-\(n)")
                n += 1
            }
            try fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }
}
