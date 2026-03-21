import Foundation

/// Manages Claude CLI discovery and tracks state.
final class ClaudeProcessManager: ObservableObject {
    @Published var claudePID: pid_t = 0
    @Published var isRunning: Bool = false
    @Published var claudeBinaryPath: String?
    @Published var processExitCode: Int32?

    init() {
        // Detect claude immediately so the toolbar shows the correct status on first render
        claudeBinaryPath = findClaudeBinary()
    }

    /// Always returns the user's login shell.
    func resolveShellCommand() -> (executable: String, args: [String], environment: [String]?) {
        return (Constants.defaultShell, ["-l"], buildEnvironment())
    }

    var claudeFound: Bool { claudeBinaryPath != nil }

    // MARK: - Private

    private func findClaudeBinary() -> String? {
        let config = AppConfiguration.shared
        if config.claudePath != "auto" {
            let path = (config.claudePath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }

        // Check known paths
        for path in Constants.claudeSearchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }

        // Use login shell to resolve PATH (picks up nvm, homebrew, etc.)
        return whichClaudeViaShell()
    }

    private func whichClaudeViaShell() -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Constants.defaultShell)
        process.arguments = ["-lc", "which claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }
}
