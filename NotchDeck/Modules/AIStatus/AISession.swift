import Foundation
import SwiftUI

enum AIAgent: String {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    /// Brand mark in Assets.xcassets (template images, tinted with `color`).
    var logoAsset: String { self == .claude ? "ClaudeLogo" : "OpenAILogo" }
    var color: Color {
        self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color.white
    }
}

enum AIState: Equatable {
    case thinking
    case tool(String)
    case waitingForUser(String?)
    case done(Date)
    case idle

    var isWorking: Bool {
        switch self {
        case .thinking, .tool, .waitingForUser: return true
        case .done, .idle: return false
        }
    }
}

struct AISession: Identifiable, Equatable {
    let id: String
    var agent: AIAgent
    var cwd: String
    var prompt: String?
    var state: AIState
    var startedAt: Date
    var lastEvent: Date

    /// Pinned when the session is first seen (git root name), so `cd` into subfolders doesn't rename it.
    var projectName: String?

    var project: String {
        if let projectName { return projectName }
        return Self.projectName(for: cwd) ?? "Unknown project"
    }

    /// Name of the enclosing git repository / worktree folder, else the folder itself.
    static func projectName(for cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = cwd
        while dir.count > 1, dir != NSHomeDirectory() {
            if fm.fileExists(atPath: dir + "/.git") { return (dir as NSString).lastPathComponent }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Higher = more important for the compact slot.
    var importance: Int {
        switch state {
        case .waitingForUser: return 3
        case .thinking, .tool: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    func elapsed(at now: Date) -> TimeInterval? {
        switch state {
        case .idle: return nil
        case .done(let at): return max(0, at.timeIntervalSince(startedAt))
        default: return max(0, now.timeIntervalSince(startedAt))
        }
    }
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Hook payload

struct HookEvent: Sendable {
    var agent: String
    var name: String
    var sessionID: String
    var cwd: String
    var prompt: String?
    var toolName: String?
    var toolLabel: String?
    var message: String?
    var notificationType: String?

    /// Defensive parse: unknown fields ignored, missing fields tolerated. Returns nil only for non-JSON-object bodies.
    static func parse(agent: String, body: Data) -> HookEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            guard let s = obj[k] as? String, !s.isEmpty else { return nil }
            return s
        }
        let name = str("hook_event_name") ?? str("hookEventName") ?? ""
        let sid = str("session_id") ?? str("sessionId") ?? "default-\(agent)"
        let tool = str("tool_name")
        let input = obj["tool_input"] as? [String: Any]
        return HookEvent(
            agent: agent, name: name, sessionID: sid,
            cwd: str("cwd") ?? "",
            prompt: str("prompt"),
            toolName: tool,
            toolLabel: tool.map { ToolLabel.make(name: $0, input: input) },
            message: str("message"),
            notificationType: str("notification_type"))
    }
}

enum ToolLabel {
    static func make(name: String, input: [String: Any]?) -> String {
        if name.hasPrefix("mcp__") {
            let last = name.components(separatedBy: "__").last ?? name
            return last.isEmpty ? name : last
        }
        switch name {
        case "Task", "Agent": return "Subagent"
        case "Bash", "shell", "local_shell", "exec_command", "container.exec":
            if let w = firstCommandWord(input?["command"] ?? input?["cmd"]) { return w }
            return name == "Bash" ? "Bash" : "Shell"
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit", "NotebookRead":
            let path = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String) ?? (input?["path"] as? String)
            if let p = path, !p.isEmpty {
                let b = (p as NSString).lastPathComponent
                if !b.isEmpty { return b }
            }
            return name
        case "apply_patch": return "Patch"
        default: return name
        }
    }

    private static func firstCommandWord(_ any: Any?) -> String? {
        var command: String?
        if let s = any as? String { command = s }
        else if let arr = any as? [String], !arr.isEmpty {
            // e.g. ["bash","-lc","npm test"] -> "npm test"
            if arr.count >= 3, ["bash", "sh", "zsh"].contains((arr[0] as NSString).lastPathComponent), arr[1].hasPrefix("-") {
                command = arr[2]
            } else { command = arr[0] }
        }
        guard let cmd = command else { return nil }
        for raw in cmd.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let tok = String(raw)
            if tok.contains("=") && !tok.hasPrefix("/") && !tok.hasPrefix("-") { continue } // FOO=1 cmd
            let base = (tok as NSString).lastPathComponent
            return base.isEmpty ? tok : base
        }
        return nil
    }
}
