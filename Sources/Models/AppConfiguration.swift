import Foundation

/// Persisted settings loaded from ~/.config/claudybro/config.json
final class AppConfiguration: ObservableObject {
    static let shared = AppConfiguration()

    @Published var fontName: String = "SF Mono"
    @Published var fontSize: CGFloat = 13
    @Published var claudePath: String = "auto"
    @Published var theme: String = "dark"
    @Published var autoCleanOrphans: Bool = false
    @Published var orphanTimeoutSeconds: Int = 30
    @Published var processMonitorInterval: Int = 5

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
            if let v = json["theme"] as? String { theme = v }
            if let v = json["autoCleanOrphans"] as? Bool { autoCleanOrphans = v }
            if let v = json["orphanTimeoutSeconds"] as? Int { orphanTimeoutSeconds = v }
            if let v = json["processMonitorInterval"] as? Int { processMonitorInterval = v }
        } catch {
            // Ignore corrupt config — use defaults
        }
    }

    func save() {
        let json: [String: Any] = [
            "font": fontName,
            "fontSize": fontSize,
            "claudePath": claudePath,
            "theme": theme,
            "autoCleanOrphans": autoCleanOrphans,
            "orphanTimeoutSeconds": orphanTimeoutSeconds,
            "processMonitorInterval": processMonitorInterval,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try data.write(to: Constants.configFile, options: .atomic)
        } catch {
            // Best-effort save
        }
    }
}
