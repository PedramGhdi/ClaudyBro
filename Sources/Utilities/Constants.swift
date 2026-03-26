import AppKit

enum Constants {
    static let tempDirectory = "/tmp/claudybro"

    static let claudeSearchPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/bin/claude",
    ]

    static let defaultShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    // Dark theme matching Claude Code aesthetic
    static let backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.180, alpha: 1.0)
    static let foregroundColor = NSColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1.0)
    static let statusBarBackground = NSColor(red: 0.075, green: 0.075, blue: 0.133, alpha: 1.0)
    static let warningColor = NSColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0)
    static let accentColor = NSColor(red: 0.35, green: 0.56, blue: 1.0, alpha: 1.0)

    static let configDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claudybro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let configFile: URL = configDirectory.appendingPathComponent("config.json")

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "pdf", "svg", "tiff", "bmp",
    ]

    static let statusTextColor = NSColor(red: 0.65, green: 0.65, blue: 0.72, alpha: 1.0)
}

// MARK: - Notification Names

extension Notification.Name {
    static let killOrphanProcesses = Notification.Name("com.claudybro.killOrphans")
    static let sendTerminalCommand = Notification.Name("com.claudybro.sendCommand")
    static let claudeProcessExited = Notification.Name("com.claudybro.claudeExited")
}
