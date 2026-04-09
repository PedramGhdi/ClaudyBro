import Foundation

/// Discovers installed AI CLI tools and tracks shell state.
final class CLIProcessManager: ObservableObject {
    @Published var shellPID: pid_t = 0
    @Published var isRunning: Bool = false
    @Published var processExitCode: Int32?

    /// Maps each detected CLI provider to its binary path.
    @Published var detectedProviders: [CLIProvider: String] = [:]

    /// True if npx is available (allows running CLIs without global install).
    @Published var npxAvailable: Bool = false

    init() {
        discoverAll()
    }

    /// Providers that were found on the system (ordered by enum case order).
    var foundProviders: [CLIProvider] {
        CLIProvider.allCases.filter { detectedProviders[$0] != nil }
    }

    /// Check if a specific provider was found.
    func isFound(_ provider: CLIProvider) -> Bool {
        detectedProviders[provider] != nil
    }

    /// Whether any CLI at all is available (installed or via npx).
    var anyCLIAvailable: Bool {
        !detectedProviders.isEmpty || npxAvailable
    }

    /// Always returns the user's login shell.
    func resolveShellCommand() -> (executable: String, args: [String], environment: [String]?) {
        return (Constants.defaultShell, ["-l"], buildEnvironment())
    }

    // MARK: - Discovery

    /// Scan for all supported CLI binaries.
    private func discoverAll() {
        var found: [CLIProvider: String] = [:]
        for provider in CLIProvider.allCases {
            if let path = findBinary(for: provider) {
                found[provider] = path
            }
        }
        detectedProviders = found
        npxAvailable = whichViaShell("npx") != nil
    }

    private func findBinary(for provider: CLIProvider) -> String? {
        // 1. Config override
        let configPath = AppConfiguration.shared.cliPath(for: provider)
        if configPath != "auto" {
            let expanded = (configPath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }

        // 2. Known paths
        for path in provider.searchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }

        // 3. `which` fallback via login shell (picks up nvm, homebrew, etc.)
        return whichViaShell(provider.binaryName)
    }

    private func whichViaShell(_ binaryName: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Constants.defaultShell)
        process.arguments = ["-lc", "which \(binaryName)"]
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
        // Tell applications we're a dark terminal (light fg on dark bg)
        // without requiring OSC 10/11 color queries
        env["COLORFGBG"] = "15;0"
        return env.map { "\($0.key)=\($0.value)" }
    }
}
