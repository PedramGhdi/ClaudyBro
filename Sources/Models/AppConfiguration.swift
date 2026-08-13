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
    /// SwiftTerm `CursorStyle.tagName`, e.g. "steadyBlock" / "blinkBar".
    @Published var cursorStyle: String = "steadyBlock"
    /// Terminal background alpha, 0.3–1.0. Below 1 the window stops being opaque.
    @Published var backgroundOpacity: Double = 1.0
    /// Frost whatever shows through a translucent background, rather than
    /// letting the raw desktop through.
    @Published var backgroundBlur: Bool = true
    /// Selecting text copies it, the way every other terminal on this machine
    /// behaves. Existing configs keep whatever they already saved.
    @Published var copyOnSelect: Bool = true
    /// Shell to spawn, or "auto" for `$SHELL`.
    @Published var shellPath: String = "auto"
    /// Rebuild the previous tab and split layout on launch.
    @Published var restoreSession: Bool = true
    /// Command run in every new terminal once the shell is ready. Empty = none.
    @Published var startupCommand: String = ""
    /// Mirror typing from the focused pane into the other panes of its tab.
    /// Not persisted — a mode this sticky should never survive a relaunch
    /// unnoticed, since every keystroke would go somewhere unexpected.
    @Published var broadcastInput: Bool = false
    @Published var orphanTimeoutSeconds: Int = 30
    @Published var processMonitorInterval: Int = 5
    @Published var autoKillTimeoutSeconds: Int = 90
    @Published var preferredCLI: String = ""
    @Published var preferredDangerousMode: Bool = false
    /// Idle seconds before a CLI-spawned helper is reaped. Live MCP servers are
    /// exempt — they only go when their CLI does.
    @Published var idleHelperKillSeconds: Int = 90
    /// Master switch for automatic process termination. When off, orphans are
    /// still detected and listed, but nothing is killed without a click.
    @Published var autoKillEnabled: Bool = true
    @Published var disableAltScreen: Bool = true
    @Published var pinnedProcessDescriptions: [String] = []
    @Published var savedPrompts: [SavedPrompt] = []

    var preferredProvider: CLIProvider? {
        CLIProvider(rawValue: preferredCLI)
    }

    /// Resolved theme from the persisted id. Falls back to ClaudyBro Dark for unknown ids.
    var currentTheme: Theme { Theme.preset(id: theme) }

    /// Modification date of the last write we made ourselves, so the watcher can
    /// tell our own saves apart from someone editing the file by hand.
    private var lastSelfWrite: Date?
    private var configWatcher: DispatchSourceFileSystemObject?

    private init() {
        load()
        startWatchingConfigFile()
    }

    // MARK: - Live reload

    /// Reload when `config.json` is edited outside the app.
    ///
    /// The directory is watched rather than the file: `save()` writes
    /// atomically, which replaces the inode and would silently detach a
    /// file-descriptor watcher after the first save.
    private func startWatchingConfigFile() {
        let fd = open(Constants.configDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reloadIfEditedExternally() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func reloadIfEditedExternally() {
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: Constants.configFile.path)[.modificationDate] as? Date
        else { return }

        // Our own save() already reflects these values in memory; reloading
        // would be redundant, and posting would loop.
        if let lastSelfWrite, modified <= lastSelfWrite { return }

        load()
        NotificationCenter.default.post(name: .configurationChanged, object: nil)
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
            if let v = json["cursorStyle"] as? String { cursorStyle = v }
            if let v = json["backgroundOpacity"] as? Double { backgroundOpacity = v }
            if let v = json["backgroundBlur"] as? Bool { backgroundBlur = v }
            if let v = json["copyOnSelect"] as? Bool { copyOnSelect = v }
            if let v = json["shellPath"] as? String { shellPath = v }
            if let v = json["restoreSession"] as? Bool { restoreSession = v }
            if let v = json["startupCommand"] as? String { startupCommand = v }
            if let v = json["orphanTimeoutSeconds"] as? Int { orphanTimeoutSeconds = v }
            if let v = json["processMonitorInterval"] as? Int { processMonitorInterval = v }
            if let v = json["autoKillTimeoutSeconds"] as? Int { autoKillTimeoutSeconds = v }
            if let v = json["preferredCLI"] as? String { preferredCLI = v }
            if let v = json["preferredDangerousMode"] as? Bool { preferredDangerousMode = v }
            // `mcpIdleKillSeconds` is the pre-1.15 name for the same timeout,
            // read so an existing config keeps its value.
            if let v = json["idleHelperKillSeconds"] as? Int {
                idleHelperKillSeconds = v
            } else if let v = json["mcpIdleKillSeconds"] as? Int {
                idleHelperKillSeconds = v
            }
            if let v = json["autoKillEnabled"] as? Bool { autoKillEnabled = v }
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
            "cursorStyle": cursorStyle,
            "backgroundOpacity": backgroundOpacity,
            "backgroundBlur": backgroundBlur,
            "copyOnSelect": copyOnSelect,
            "shellPath": shellPath,
            "restoreSession": restoreSession,
            "startupCommand": startupCommand,
            "orphanTimeoutSeconds": orphanTimeoutSeconds,
            "processMonitorInterval": processMonitorInterval,
            "autoKillTimeoutSeconds": autoKillTimeoutSeconds,
            "preferredCLI": preferredCLI,
            "preferredDangerousMode": preferredDangerousMode,
            "idleHelperKillSeconds": idleHelperKillSeconds,
            "autoKillEnabled": autoKillEnabled,
            "disableAltScreen": disableAltScreen,
            "pinnedProcessDescriptions": pinnedProcessDescriptions,
            "savedPrompts": savedPrompts.map { ["id": $0.id.uuidString, "name": $0.name, "body": $0.body] },
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            try data.write(to: Constants.configFile, options: .atomic)
            lastSelfWrite = try? FileManager.default
                .attributesOfItem(atPath: Constants.configFile.path)[.modificationDate] as? Date
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
