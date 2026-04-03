import Foundation

/// Auto-configures Claude Code's statusLine to write session data to a temp file
/// that ClaudyBro reads for its status bar display.
enum StatusLineBridge {

    private static let scriptPath = NSHomeDirectory() + "/.claude/statusline-command.sh"
    private static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

    private static let scriptContent =
        "#!/bin/sh\n# ClaudyBro context bridge\ncat > /tmp/claudybro-context.json\n"

    /// Ensure the statusLine bridge script exists and is configured in Claude's settings.
    /// Runs on a background thread — safe to call from applicationDidFinishLaunching.
    static func ensureConfigured() {
        DispatchQueue.global(qos: .utility).async {
            ensureScriptExists()
            ensureSettingsConfigured()
        }
    }

    private static func ensureScriptExists() {
        let fm = FileManager.default

        // Skip if script already exists with correct content
        if let existing = fm.contents(atPath: scriptPath),
           let text = String(data: existing, encoding: .utf8),
           text == scriptContent {
            return
        }

        // Create ~/.claude/ if needed
        let claudeDir = (scriptPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: claudeDir) {
            try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    private static func ensureSettingsConfigured() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Already configured — skip
        if let existing = json["statusLine"] as? [String: Any],
           let command = existing["command"] as? String,
           command.contains("claudybro") {
            return
        }

        json["statusLine"] = [
            "type": "command",
            "command": "bash " + scriptPath,
        ] as [String: Any]

        guard let updated = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? updated.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }
}
