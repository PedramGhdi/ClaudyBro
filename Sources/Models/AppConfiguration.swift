import Foundation

/// Persisted settings loaded from ~/.config/claudybro/config.json
final class AppConfiguration: ObservableObject {
    static let shared = AppConfiguration()

    @Published var fontName: String = "SF Mono"
    @Published var fontSize: CGFloat = 13
    @Published var claudePath: String = "auto"
    @Published var geminiPath: String = "auto"
    @Published var codexPath: String = "auto"
    @Published var theme: String = "dark"
    @Published var orphanTimeoutSeconds: Int = 30
    @Published var processMonitorInterval: Int = 5
    @Published var autoKillTimeoutSeconds: Int = 90
    @Published var preferredCLI: String = ""
    @Published var preferredDangerousMode: Bool = false
    @Published var mcpStandbyEnabled: Bool = true
    @Published var mcpStandbyIdleSeconds: Int = 90

    var preferredProvider: CLIProvider? {
        CLIProvider(rawValue: preferredCLI)
    }

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
            if let v = json["theme"] as? String { theme = v }
            if let v = json["orphanTimeoutSeconds"] as? Int { orphanTimeoutSeconds = v }
            if let v = json["processMonitorInterval"] as? Int { processMonitorInterval = v }
            if let v = json["autoKillTimeoutSeconds"] as? Int { autoKillTimeoutSeconds = v }
            if let v = json["preferredCLI"] as? String { preferredCLI = v }
            if let v = json["preferredDangerousMode"] as? Bool { preferredDangerousMode = v }
            if let v = json["mcpStandbyEnabled"] as? Bool { mcpStandbyEnabled = v }
            if let v = json["mcpStandbyIdleSeconds"] as? Int { mcpStandbyIdleSeconds = v }
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
            "theme": theme,
            "orphanTimeoutSeconds": orphanTimeoutSeconds,
            "processMonitorInterval": processMonitorInterval,
            "autoKillTimeoutSeconds": autoKillTimeoutSeconds,
            "preferredCLI": preferredCLI,
            "preferredDangerousMode": preferredDangerousMode,
            "mcpStandbyEnabled": mcpStandbyEnabled,
            "mcpStandbyIdleSeconds": mcpStandbyIdleSeconds,
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
        }
    }

    func setCLIPath(for provider: CLIProvider, _ value: String) {
        switch provider {
        case .claude: claudePath = value
        case .gemini: geminiPath = value
        case .codex:  codexPath = value
        }
    }
}
