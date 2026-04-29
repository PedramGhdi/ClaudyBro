import Foundation

/// Auto-configures the statusLine for any installed CLI that supports it
/// (see CLIProvider.supportsStatusLine), pointing it at a temp file
/// ClaudyBro reads for its status bar display.
///
/// Only runs for providers whose configDirectory already exists — a strong
/// signal the user has actually used that CLI. We never create a fresh
/// `~/.claude/` (or sibling) for a user who only runs Gemini/Kilo.
enum StatusLineBridge {

    private static let scriptContent =
        "#!/bin/sh\n# ClaudyBro context bridge\ncat > /tmp/claudybro-context.json\n"

    /// Install the statusLine bridge for every supported CLI whose config
    /// directory already exists. Background thread — safe to call from
    /// applicationDidFinishLaunching.
    static func ensureConfigured() {
        DispatchQueue.global(qos: .utility).async {
            for provider in CLIProvider.allCases where provider.supportsStatusLine {
                guard let dir = provider.configDirectory,
                      FileManager.default.fileExists(atPath: dir)
                else { continue }
                let scriptPath = dir + "/statusline-command.sh"
                let settingsPath = dir + "/settings.json"
                ensureScriptExists(at: scriptPath)
                ensureSettingsConfigured(scriptPath: scriptPath, settingsPath: settingsPath)
            }
        }
    }

    private static func ensureScriptExists(at scriptPath: String) {
        let fm = FileManager.default

        if let existing = fm.contents(atPath: scriptPath),
           let text = String(data: existing, encoding: .utf8),
           text == scriptContent {
            return
        }

        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    private static func ensureSettingsConfigured(scriptPath: String, settingsPath: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

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
