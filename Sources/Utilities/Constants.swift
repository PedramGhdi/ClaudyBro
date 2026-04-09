import AppKit
import SwiftTerm

enum Constants {
    static let tempDirectory = "/tmp/claudybro"

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

    // MARK: - ANSI Color Palette

    /// 16-color ANSI palette tuned for our dark navy background (#1a1a2e).
    /// Color 0 (black) matches the background so CLI block elements blend seamlessly.
    static let ansiPalette: [SwiftTerm.Color] = {
        func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
            SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
        }
        return [
            // Normal (0-7)
            c( 26,  26,  46),  // 0 black  — matches background
            c(255,  85,  85),  // 1 red
            c( 80, 250, 123),  // 2 green
            c(255, 204,   0),  // 3 yellow
            c( 89, 143, 255),  // 4 blue
            c(209,  97, 255),  // 5 magenta
            c(  0, 205, 205),  // 6 cyan
            c(224, 224, 224),  // 7 white
            // Bright (8-15)
            c( 75,  75, 100),  // 8  bright black
            c(255, 110, 110),  // 9  bright red
            c(105, 255, 148),  // 10 bright green
            c(255, 225,  80),  // 11 bright yellow
            c(120, 170, 255),  // 12 bright blue
            c(225, 130, 255),  // 13 bright magenta
            c( 80, 230, 230),  // 14 bright cyan
            c(255, 255, 255),  // 15 bright white
        ]
    }()
}

// MARK: - Notification Names

extension Notification.Name {
    static let killOrphanProcesses = Notification.Name("com.claudybro.killOrphans")
    static let sendTerminalCommand = Notification.Name("com.claudybro.sendCommand")
    static let cliProcessExited = Notification.Name("com.claudybro.cliExited")
    static let configurationChanged = Notification.Name("com.claudybro.configChanged")
}
