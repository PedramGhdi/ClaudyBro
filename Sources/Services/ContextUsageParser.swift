import Foundation

/// Parsed context/token usage from a CLI session.
struct ContextUsage: Equatable {
    var usedPercentage: Int?
    var modelName: String?
    var cost: String?
    var modeIndicator: String?
    var effort: String?

    var isEmpty: Bool {
        usedPercentage == nil && modelName == nil && cost == nil
            && modeIndicator == nil && effort == nil
    }
}

/// Reads CLI context data from the JSON file written by the statusline command.
enum ContextUsageParser {

    static let contextFilePath = "/tmp/claudybro-context.json"

    // Pre-compiled patterns — allocated once, reused every call
    private static let effortPattern = try! NSRegularExpression(
        pattern: #"[●•]\s*(high|medium|low)"#, options: .caseInsensitive
    )
    private static let bypassPattern = try! NSRegularExpression(
        pattern: #"bypass\s+permissions?\s+on"#, options: .caseInsensitive
    )
    private static let parenSuffixPattern = try! NSRegularExpression(
        pattern: #"\s*\(.*\)$"#, options: []
    )

    /// Parse terminal buffer lines for mode/effort info not available in the JSON.
    static func parseStatusLine(lines: [String]) -> (mode: String?, effort: String?) {
        var mode: String?
        var effort: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            if effort == nil,
               let match = effortPattern.firstMatch(in: trimmed, range: range),
               let r = Range(match.range(at: 1), in: trimmed) {
                effort = String(trimmed[r]).lowercased()
            }

            if mode == nil,
               bypassPattern.firstMatch(in: trimmed, range: range) != nil {
                mode = "bypass"
            }

            if mode != nil && effort != nil { break }
        }

        return (mode, effort)
    }

    /// Read and parse the context JSON file written by Claude Code's statusline command.
    static func readFromFile() -> ContextUsage {
        guard let data = FileManager.default.contents(atPath: contextFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ContextUsage() }

        var usage = ContextUsage()

        // Context window usage
        if let ctx = json["context_window"] as? [String: Any],
           let used = ctx["used_percentage"] as? Double {
            usage.usedPercentage = Int(used.rounded())
        }

        // Model name — shorten "Opus 4.6 (1M context)" → "Opus 4.6"
        if let model = json["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty {
            let nsRange = NSRange(name.startIndex..., in: name)
            if let match = parenSuffixPattern.firstMatch(in: name, range: nsRange),
               let r = Range(match.range, in: name) {
                usage.modelName = String(name[name.startIndex..<r.lowerBound])
            } else {
                usage.modelName = name
            }
        }

        // Cost
        if let costObj = json["cost"] as? [String: Any],
           let totalCost = costObj["total_cost_usd"] as? Double, totalCost > 0 {
            usage.cost = String(format: "$%.2f", totalCost)
        }

        // Effort — not included in statusLine JSON, read from Claude Code settings.
        // Check project-level settings first (using cwd from JSON), then global.
        let projectDir = json["cwd"] as? String
        usage.effort = readEffortFromSettings(projectDir: projectDir)

        return usage
    }

    // MARK: - Claude Code Settings

    private static let globalSettingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let globalLocalSettingsPath = NSHomeDirectory() + "/.claude/settings.local.json"

    /// Read effortLevel from Claude Code's settings files.
    /// Precedence: project local > project > global local > global.
    static func readEffortFromSettings(projectDir: String?) -> String? {
        var paths: [String] = []
        if let dir = projectDir {
            paths.append(dir + "/.claude/settings.local.json")
            paths.append(dir + "/.claude/settings.json")
        }
        paths.append(globalLocalSettingsPath)
        paths.append(globalSettingsPath)

        let fm = FileManager.default
        for path in paths {
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let effort = json["effortLevel"] as? String, !effort.isEmpty
            else { continue }
            return effort
        }
        return nil
    }
}
