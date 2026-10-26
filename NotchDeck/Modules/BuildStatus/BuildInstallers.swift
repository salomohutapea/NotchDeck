import Foundation

/// Installs the `ndrun` wrapper and the Gradle init-script hook.
enum BuildInstallers {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchDeck", isDirectory: true)
    static let ndrunURL = support.appendingPathComponent("bin/ndrun")
    static let pathSnippet = #"export PATH="$HOME/Library/Application Support/NotchDeck/bin:$PATH""#
    static let aliasSnippet = #"alias ndrun='"$HOME/Library/Application Support/NotchDeck/bin/ndrun"'"#
    static let marker = "NotchDeck build hook"

    // MARK: ndrun

    static var bundledNdrun: URL? {
        Bundle.main.url(forResource: "ndrun", withExtension: "sh")
            ?? Bundle.main.url(forResource: "ndrun", withExtension: "sh", subdirectory: "build")
    }

    static var ndrunInstalled: Bool {
        guard let s = try? String(contentsOf: ndrunURL, encoding: .utf8) else { return false }
        return s.contains("NotchDeck build wrapper")
    }

    static var ndrunUpToDate: Bool {
        guard let src = bundledNdrun, let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: ndrunURL) else { return false }
        return a == b
    }

    static func installNdrun() throws {
        guard let src = bundledNdrun else { throw InstallError("ndrun.sh is missing from the app bundle.") }
        let fm = FileManager.default
        try fm.createDirectory(at: ndrunURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: BuildSpool.directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ndrunURL.path) { try fm.removeItem(at: ndrunURL) }
        try fm.copyItem(at: src, to: ndrunURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ndrunURL.path)
    }

    static func uninstallNdrun() throws {
        if ndrunInstalled { try FileManager.default.removeItem(at: ndrunURL) }
    }

    // MARK: Gradle

    static let gradleHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gradle", isDirectory: true)
    static var initScriptURL: URL { gradleHome.appendingPathComponent("init.d/notchdeck.gradle") }
    static var flowScriptURL: URL { gradleHome.appendingPathComponent("notchdeck/notchdeck-flow.gradle") }

    static var gradleHookInstalled: Bool {
        guard let s = try? String(contentsOf: initScriptURL, encoding: .utf8) else { return false }
        return s.contains(marker)
    }

    static func installGradleHook() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: initScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: flowScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Back up a foreign file occupying our name (our own file is simply replaced: idempotent).
        if fm.fileExists(atPath: initScriptURL.path), !gradleHookInstalled {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try fm.copyItem(at: initScriptURL, to: initScriptURL.appendingPathExtension("bak-\(stamp)"))
        }
        try GradleHookScripts.flow.write(to: flowScriptURL, atomically: true, encoding: .utf8)
        try GradleHookScripts.initScript.write(to: initScriptURL, atomically: true, encoding: .utf8)
    }

    static func uninstallGradleHook() throws {
        let fm = FileManager.default
        if gradleHookInstalled { try fm.removeItem(at: initScriptURL) }
        if fm.fileExists(atPath: flowScriptURL.path) { try fm.removeItem(at: flowScriptURL) }
        let dir = flowScriptURL.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
