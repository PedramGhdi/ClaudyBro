import Foundation

/// Persisted settings loaded from ~/.config/claudybro/config.json
final class AppConfiguration: ObservableObject {
    static let shared = AppConfiguration()

    @Published var fontName: String = "SF Mono"
    @Published var fontSize: CGFloat = 13
    @Published var claudePath: String = "auto"
    @Published var geminiPath: String = "auto"
    @Published var codexPath: String = "auto"
    @Published var kiloPath: String = "auto"
    @Published var theme: String = Theme.claudyBroDark.id
    @Published var orphanTimeoutSeconds: Int = 30
    @Published var processMonitorInterval: Int = 5
    @Published var autoKillTimeoutSeconds: Int = 90
    @Published var preferredCLI: String = ""
    @Published var preferredDangerousMode: Bool = false
    @Published var mcpIdleKillSeconds: Int = 90
    @Published var disableAltScreen: Bool = true
    @Published var pinnedProcessDescriptions: [String] = []
    @Published var savedPrompts: [SavedPrompt] = []

    var preferredProvider: CLIProvider? {
        CLIProvider(rawValue: preferredCLI)
    }

    /// Resolved theme from the persisted id. Falls back to ClaudyBro Dark for unknown ids.
    var currentTheme: Theme { Theme.preset(id: theme) }

    private init() {
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: Constants.configFile.path) else { return }
        do {
            let data = try Data(contentsOf: Constants.configFile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let v = json["font"] as? String { fontName = v }
            if let v = json["fontSize"] as? CGFloat { fontSize = v }
            if let v = json["claudePath"] as? String { claudePath = v }
            if let v = json["geminiPath"] as? String { geminiPath = v }
            if let v = json["codexPath"] as? String { codexPath = v }
            if let v = json["kiloPath"] as? String { kiloPath = v }
            if let v = json["theme"] as? String { theme = v }
            if let v = json["orphanTimeoutSeconds"] as? Int { orphanTimeoutSeconds = v }
            if let v = json["processMonitorInterval"] as? Int { processMonitorInterval = v }
            if let v = json["autoKillTimeoutSeconds"] as? Int { autoKillTimeoutSeconds = v }
            if let v = json["preferredCLI"] as? String { preferredCLI = v }
            if let v = json["preferredDangerousMode"] as? Bool { preferredDangerousMode = v }
            if let v = json["mcpIdleKillSeconds"] as? Int { mcpIdleKillSeconds = v }
            if let v = json["disableAltScreen"] as? Bool { disableAltScreen = v }

            if let v = json["pinnedProcessDescriptions"] as? [String] { pinnedProcessDescriptions = v }
            if let arr = json["savedPrompts"] as? [[String: Any]] {
                savedPrompts = arr.compactMap { dict in
                    guard let name = dict["name"] as? String,
                          let body = dict["body"] as? String else { return nil }
                    let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                    return SavedPrompt(id: id, name: name, body: body)
                }
            }
        } catch {
            // Ignore corrupt config — use defaults
        }
    }

    func save() {
        let json: [String: Any] = [
            "font": fontName,
            "fontSize": fontSize,
            "claudePath": claudePath,
            "geminiPath": geminiPath,
            "codexPath": codexPath,
            "kiloPath": kiloPath,
            "theme": theme,
            "orphanTimeoutSeconds": orphanTimeoutSeconds,
            "processMonitorInterval": processMonitorInterval,
            "autoKillTimeoutSeconds": autoKillTimeoutSeconds,
            "preferredCLI": preferredCLI,
            "preferredDangerousMode": preferredDangerousMode,
            "mcpIdleKillSeconds": mcpIdleKillSeconds,
            "disableAltScreen": disableAltScreen,
            "pinnedProcessDescriptions": pinnedProcessDescriptions,
            "savedPrompts": savedPrompts.map { ["id": $0.id.uuidString, "name": $0.name, "body": $0.body] },
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try data.write(to: Constants.configFile, options: .atomic)
        } catch {
            // Best-effort save
        }
    }

    // MARK: - Generic CLI Path Accessors

    func cliPath(for provider: CLIProvider) -> String {
        switch provider {
        case .claude: return claudePath
        case .gemini: return geminiPath
        case .codex:  return codexPath
        case .kilo:   return kiloPath
        }
    }

    func setCLIPath(for provider: CLIProvider, _ value: String) {
        switch provider {
        case .claude: claudePath = value
        case .gemini: geminiPath = value
        case .codex:  codexPath = value
        case .kilo:   kiloPath = value
        }
    }
}
