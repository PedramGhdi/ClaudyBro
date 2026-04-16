import AppKit

/// All supported AI CLI tools. Adding a new CLI = adding a new case + filling in the computed properties.
/// The compiler enforces exhaustive coverage via switch statements.
enum CLIProvider: String, CaseIterable, Codable, Identifiable {
    case claude
    case gemini
    case codex
    case kilo

    var id: String { rawValue }

    /// The binary name to search for in PATH.
    var binaryName: String {
        switch self {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex:  return "codex"
        case .kilo:   return "kilo"
        }
    }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .codex:  return "Codex"
        case .kilo:   return "Kilo"
        }
    }

    /// SF Symbol name for UI.
    var iconName: String {
        switch self {
        case .claude: return "brain"
        case .gemini: return "sparkles"
        case .codex:  return "terminal"
        case .kilo:   return "bolt"
        }
    }

    /// Brand color for UI indicators.
    var color: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.25, green: 0.50, blue: 0.95, alpha: 1.0)
        case .gemini: return NSColor(red: 0.30, green: 0.65, blue: 0.95, alpha: 1.0)
        case .codex:  return .systemGreen
        case .kilo:   return .systemOrange
        }
    }

    /// Well-known filesystem paths to search before falling back to `which`.
    var searchPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claude:
            return [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/bin/claude",
            ]
        case .gemini:
            return [
                "/usr/local/bin/gemini",
                "/opt/homebrew/bin/gemini",
                "\(home)/.npm-global/bin/gemini",
            ]
        case .codex:
            return [
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                "\(home)/.npm-global/bin/codex",
            ]
        case .kilo:
            return [
                "/usr/local/bin/kilo",
                "/opt/homebrew/bin/kilo",
                "\(home)/.npm-global/bin/kilo",
            ]
        }
    }

    /// npm package name for running via npx without global install. Nil if not applicable.
    var npxPackage: String? {
        switch self {
        case .claude: return "@anthropic-ai/claude-code"
        case .gemini: return "@google/gemini-cli"
        case .codex:  return "@openai/codex"
        case .kilo:   return "@kilocode/cli"
        }
    }

    /// The default launch command (just the binary name).
    var launchCommand: String { binaryName }

    /// Command to launch via npx (for users without global install).
    var npxLaunchCommand: String? {
        guard let pkg = npxPackage else { return nil }
        return "npx -y \(pkg)"
    }

    /// Optional "power mode" variant (skip permissions / full auto). Nil if none exists.
    var dangerousLaunchCommand: String? {
        switch self {
        case .claude: return "claude --dangerously-skip-permissions"
        case .gemini: return nil
        case .codex:  return "codex --full-auto"
        case .kilo:   return nil
        }
    }

    /// Label for the dangerous-mode button. Nil if dangerousLaunchCommand is nil.
    var dangerousButtonLabel: String? {
        switch self {
        case .claude: return "Skip Permissions"
        case .gemini: return nil
        case .codex:  return "Full Auto"
        case .kilo:   return nil
        }
    }

    /// Process-name keyword used to detect this CLI in the process tree.
    var processKeyword: String { binaryName }

    /// Human-readable description returned by describeProcess() when this CLI is detected.
    var processDescription: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .codex:  return "Codex CLI"
        case .kilo:   return "Kilo Code"
        }
    }

    /// Config key for the custom binary path in config.json.
    var configPathKey: String { "\(rawValue)Path" }
}
