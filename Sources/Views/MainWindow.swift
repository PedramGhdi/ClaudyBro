import SwiftTerm
import SwiftUI

/// Root content view: tab bar + launch toolbar + terminal sessions + status bar.
struct MainWindow: View {
    @StateObject private var tabManager = TabManager()
    @ObservedObject private var config = AppConfiguration.shared
    @State private var showSettings = false
    @State private var showCommandPalette = false
    @State private var windowTitle: String = "ClaudyBro"

    private var isTranslucent: Bool { config.backgroundOpacity < 1.0 }

    var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                TabBarView(tabManager: tabManager)
            }

            if let tab = tabManager.activeTab {
                LaunchToolbar(
                    processManager: tab.activePane.processManager,
                    processMonitor: tab.activePane.processMonitor
                )
            }

            // Render every tab so background tabs keep their PTYs alive,
            // but only the active tab is visible / hit-testable.
            ZStack {
                ForEach(tabManager.tabs) { tab in
                    TabPaneTreeView(
                        tab: tab,
                        isActiveTab: tab.id == tabManager.activeTabId
                    )
                    .opacity(tab.id == tabManager.activeTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.activeTabId)
                }
            }

            if let tab = tabManager.activeTab {
                StatusBarView(
                    processMonitor: tab.activePane.processMonitor,
                    shellPID: tab.activePane.processManager.shellPID
                )
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background {
            // With a translucent terminal background, whatever sits behind it
            // shows through. Blur frosts it; otherwise it is the plain desktop.
            if isTranslucent {
                if config.backgroundBlur {
                    VisualEffectBackground()
                } else {
                    Color.clear
                }
            } else {
                Color(nsColor: config.currentTheme.background)
            }
        }
        .background(WindowConfigurator(isTranslucent: isTranslucent))
        .preferredColorScheme(.dark)
        .navigationTitle(windowTitle)
        .onAppear { AppDelegate.tabManager = tabManager }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showCommandPalette) {
            if let tab = tabManager.activeTab {
                CommandPaletteView(
                    isPresented: $showCommandPalette,
                    providers: CLIProvider.allCases,
                    installedProviders: Set(tab.activePane.processManager.foundProviders),
                    npxAvailable: tab.activePane.processManager.npxAvailable
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPalette)) { _ in
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
            let dir = tabManager.activeTab?.activePane.processMonitor.currentDirectory
            tabManager.addNewTab(initialDirectory: dir?.isEmpty == false ? dir : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            if let id = tabManager.activeTabId { tabManager.requestCloseTab(id: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitPaneVertical)) { _ in
            tabManager.activeTab?.splitActivePane(direction: .vertical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitPaneHorizontal)) { _ in
            tabManager.activeTab?.splitActivePane(direction: .horizontal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePane)) { _ in
            guard let tab = tabManager.activeTab else { return }
            if tab.closeActivePane() {
                // Last pane in tab — close the whole tab.
                if let id = tabManager.activeTabId { tabManager.requestCloseTab(id: id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextPane)) { _ in
            tabManager.activeTab?.focusNextPane()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { _ in
            tabManager.selectNextTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousTab)) { _ in
            tabManager.selectPreviousTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTabByIndex)) { notification in
            if let index = notification.userInfo?["index"] as? Int {
                tabManager.selectTabByIndex(index)
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            updateWindowTitle()
        }
        .onChange(of: tabManager.activeTabId) { _ in updateWindowTitle() }
    }

    private func updateWindowTitle() {
        guard let tab = tabManager.activeTab else { windowTitle = "ClaudyBro"; return }
        let monitor = tab.activePane.processMonitor
        // Keep lastWorkingDirectory fresh so app restart uses the latest cwd.
        // Always the real path, never the shell-set title.
        if !monitor.currentDirectory.isEmpty {
            UserDefaults.standard.set(monitor.currentDirectory, forKey: "lastWorkingDirectory")
        }
        let title = monitor.displayTitle
        let resolved = title.isEmpty ? "ClaudyBro" : title
        if resolved != windowTitle { windowTitle = resolved }
    }
}

// MARK: - Launch Toolbar

struct LaunchToolbar: View {
    @ObservedObject var processManager: CLIProcessManager
    @ObservedObject var processMonitor: ProcessMonitor

    @ObservedObject private var config = AppConfiguration.shared

    /// The default CLI shown on the primary button (preferred > first found > first npx).
    private var defaultProvider: CLIProvider? {
        if let preferred = config.preferredProvider,
           processManager.isFound(preferred) || (processManager.npxAvailable && preferred.npxPackage != nil) {
            return preferred
        }
        return processManager.foundProviders.first
            ?? CLIProvider.allCases.first(where: { processManager.npxAvailable && $0.npxPackage != nil })
    }

    /// Whether the default button should launch in dangerous mode.
    private var defaultDangerousMode: Bool {
        guard let preferred = config.preferredProvider,
              preferred == defaultProvider,
              processManager.isFound(preferred) else { return false }
        return config.preferredDangerousMode && preferred.dangerousLaunchCommand != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(processManager.anyCLIAvailable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            Text(abbreviatedPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: Constants.statusTextColor))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if let provider = defaultProvider {
                // Split button: [▶ Claude | ▾]
                HStack(spacing: 0) {
                    // Primary action — one-click run of preferred CLI + mode
                    let isInstalled = processManager.isFound(provider)
                    let useDangerous = defaultDangerousMode
                    Button(action: { runCLI(provider, dangerousMode: useDangerous, viaNpx: !isInstalled) }) {
                        HStack(spacing: 4) {
                            Image(systemName: useDangerous ? "bolt.fill" : "play.fill").font(.system(size: 9))
                            Text(provider.displayName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)

                    // Divider line
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: 16)

                    // Dropdown chevron — all CLI options
                    Menu {
                        ForEach(availableProviders, id: \.provider.id) { entry in
                            Section {
                                // Normal run
                                Button(action: { runCLI(entry.provider, dangerousMode: false, viaNpx: !entry.isInstalled) }) {
                                    Label(
                                        entry.isInstalled ? "Run \(entry.provider.displayName)" : "npx \(entry.provider.displayName)",
                                        systemImage: entry.provider.iconName
                                    )
                                }

                                // Dangerous mode (if applicable and installed)
                                if entry.isInstalled, let label = entry.provider.dangerousButtonLabel {
                                    Button(action: { runCLI(entry.provider, dangerousMode: true, viaNpx: false) }) {
                                        Label("\(entry.provider.displayName) — \(label)", systemImage: "bolt.fill")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .cursor(.pointingHand)
                }
                .background(Color(nsColor: provider.color))
                .cornerRadius(4)
            } else {
                Text("No AI CLIs detected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: Constants.statusTextColor))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 28)
        .background(Color(nsColor: AppConfiguration.shared.currentTheme.statusBarBackground))
    }

    // MARK: - Helpers

    private struct ProviderEntry {
        let provider: CLIProvider
        let isInstalled: Bool
    }

    private var availableProviders: [ProviderEntry] {
        CLIProvider.allCases.compactMap { provider in
            let installed = processManager.isFound(provider)
            let canNpx = !installed && processManager.npxAvailable && provider.npxPackage != nil
            guard installed || canNpx else { return nil }
            return ProviderEntry(provider: provider, isInstalled: installed)
        }
    }

    private var abbreviatedPath: String {
        let currentPath = processMonitor.currentDirectory
        guard !currentPath.isEmpty else {
            let found = processManager.foundProviders
            if found.isEmpty && !processManager.npxAvailable {
                return "No AI CLIs detected"
            }
            if found.isEmpty {
                return "AI CLIs available via npx"
            }
            return found.map(\.displayName).joined(separator: ", ") + " available"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentPath.hasPrefix(home) {
            return "~" + currentPath.dropFirst(home.count)
        }
        return currentPath
    }

    private func runCLI(_ provider: CLIProvider, dangerousMode: Bool, viaNpx: Bool) {
        // Remember this selection as the new default
        config.preferredCLI = provider.rawValue
        config.preferredDangerousMode = dangerousMode
        config.save()

        var command: String
        if viaNpx {
            command = provider.npxLaunchCommand ?? provider.launchCommand
        } else if dangerousMode {
            command = provider.dangerousLaunchCommand ?? provider.launchCommand
        } else {
            command = provider.launchCommand
        }
        command += "\n"

        // If a CLI is already running, kill it first (Ctrl+C), then launch the new one.
        // Identity comes from the cached provider rather than a substring match
        // on the description — the latter also matched innocent commands that
        // merely mentioned a CLI name, e.g. `ssh user@codex-prod`.
        let cliPids = processMonitor.childProcesses
            .filter { $0.cliProvider != nil }
            .map(\.pid)

        if !cliPids.isEmpty {
            // Kill the running CLI process and wait for it to exit before launching new one
            for pid in cliPids { kill(pid, SIGTERM) }
            // Poll until the CLI process is gone, then send the new command
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if cliPids.allSatisfy({ !ProcessTreeQuery.isProcessAlive($0) }) { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                Thread.sleep(forTimeInterval: 0.2) // Let shell settle
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .sendTerminalCommand, object: nil,
                        userInfo: ["command": command]
                    )
                }
            }
        } else {
            NotificationCenter.default.post(
                name: .sendTerminalCommand, object: nil,
                userInfo: ["command": command]
            )
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject private var config = AppConfiguration.shared
    @Environment(\.dismiss) private var dismiss

    /// The installed monospaced families, plus the configured one when it is
    /// not among them — a hand-edited config or an uninstalled font would
    /// otherwise leave the picker showing nothing at all.
    private var fontFamilies: [String] {
        let families = FontCatalog.monospacedFamilies
        return families.contains(config.fontName) ? families : [config.fontName] + families
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $config.theme) {
                    ForEach(Theme.allPresets) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Stepper("Font Size: \(Int(config.fontSize))", value: $config.fontSize, in: 8...32, step: 1)
                Picker("Font Family", selection: $config.fontName) {
                    ForEach(fontFamilies, id: \.self) { family in
                        // A configured font that is not installed still renders
                        // as the system monospaced face, so say so rather than
                        // letting the picker claim a font that isn't in use.
                        Text(FontCatalog.font(named: family, size: 12) == nil
                            ? "\(family) — not installed"
                            : family)
                            .tag(family)
                    }
                }
                Text("Monospaced fonts installed on this Mac.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("CLI Paths") {
                ForEach(CLIProvider.allCases) { provider in
                    HStack {
                        Text("\(provider.displayName) Binary")
                        Spacer()
                        TextField("auto", text: Binding(
                            get: { config.cliPath(for: provider) },
                            set: { config.setCLIPath(for: provider, $0) }
                        ))
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Section("Shell") {
                LabeledContent("Shell") {
                    TextField("auto", text: $config.shellPath)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                Text("\"auto\" uses $SHELL (\(URL(fileURLWithPath: Constants.defaultShell).lastPathComponent)). New terminals only.")
                    .font(.caption).foregroundColor(.secondary)

                LabeledContent("Run on start") {
                    TextField("none", text: $config.startupCommand)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Runs in every new terminal, tab, and split.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Restore tabs and splits on launch", isOn: $config.restoreSession)
                Text("Rebuilds the layout and working directories. Programs that were running are not restarted.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Terminal") {
                LabeledContent("Background") {
                    HStack {
                        Slider(value: $config.backgroundOpacity, in: 0.3...1.0)
                        Text("\(Int(config.backgroundOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Blur behind window", isOn: $config.backgroundBlur)
                    .disabled(config.backgroundOpacity >= 1.0)

                Picker("Cursor", selection: $config.cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.tagName) { style in
                        Text(style.displayName).tag(style.tagName)
                    }
                }

                Toggle("Copy on select", isOn: $config.copyOnSelect)

                ShellIntegrationRow()

                Toggle("Full scrollback for AI CLIs", isOn: $config.disableAltScreen)
                Text("Keeps CLI conversation history in the scrollback instead of a throwaway screen. Applies only while a CLI is in the foreground — vim, less, htop and SSH sessions always get a normal full-screen view.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Saved Prompts") {
                if config.savedPrompts.isEmpty {
                    Text("Add reusable prompts surfaced in the command palette (⌘⇧P).")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach($config.savedPrompts) { $prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $prompt.name)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                config.savedPrompts.removeAll { $0.id == prompt.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        TextField("Prompt body", text: $prompt.body, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    config.savedPrompts.append(SavedPrompt(name: "New prompt", body: ""))
                } label: {
                    Label("Add prompt", systemImage: "plus")
                }
            }
            Section("Process Monitor") {
                Toggle("Automatically clean up leftover processes", isOn: $config.autoKillEnabled)
                Text("Only processes started by an AI CLI are ever terminated — MCP servers, subagent workers and one-shot helpers it left behind. Commands you run yourself (ssh, vim, docker…) are listed but never killed.")
                    .font(.caption).foregroundColor(.secondary)

                StepperField(label: "Auto-kill orphans after:",
                             value: $config.autoKillTimeoutSeconds, range: 0...600, step: 10)
                Text("0s = kill immediately once an orphan is confirmed")
                    .font(.caption).foregroundColor(.secondary)
                StepperField(label: "Orphan timeout:",
                             value: $config.orphanTimeoutSeconds, range: 5...300, step: 5)
                StepperField(label: "Monitor interval:",
                             value: $config.processMonitorInterval, range: 1...30, step: 1)
                StepperField(label: "Kill idle CLI helpers after:",
                             value: $config.idleHelperKillSeconds, range: 0...600, step: 30)
                Text("One-shot helpers a CLI leaves running — npm, node, shell pipelines. MCP servers are never killed while their CLI is running: no CLI respawns one, so the session would lose those tools until you run /mcp reconnect. They go when the CLI exits. 0s = kill as soon as idle.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 540)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    config.save()
                    NotificationCenter.default.post(name: .configurationChanged, object: nil)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Shell Integration

/// Settings row for installing the OSC 133 shell hooks.
///
/// Deliberately a button rather than something done at launch: it appends a
/// line to the user's rc file, and silently editing someone's shell config is
/// not a thing an app should do on its own.
private struct ShellIntegrationRow: View {
    @State private var installed = false
    @State private var error: String?

    private var shell: ShellIntegration.Shell? { ShellIntegration.current }

    var body: some View {
        Group {
            if let shell {
                LabeledContent("Prompt marks (⌘↑ / ⌘↓)") {
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Install for \(shell.rawValue)") { install(shell) }
                    }
                }
                Text(installed
                    ? "Adds a line to ~/.\(shell.rawValue)rc sourcing \(shell.scriptName). Restart your shell if jumping does nothing yet."
                    : "Jumping between prompts needs your shell to mark where they start. This appends one line to ~/.\(shell.rawValue)rc.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Prompt marks require zsh or bash; \(URL(fileURLWithPath: Constants.defaultShell).lastPathComponent) is not supported yet.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .onAppear { installed = shell.map(ShellIntegration.isInstalled) ?? false }
    }

    private func install(_ shell: ShellIntegration.Shell) {
        do {
            try ShellIntegration.install(for: shell)
            installed = true
            error = nil
        } catch {
            self.error = "Could not write to ~/.\(shell.rawValue)rc: \(error.localizedDescription)"
        }
    }
}

// MARK: - Stepper with Text Field

private struct StepperField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: $value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
            Text("s")
                .foregroundColor(.secondary)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .onChange(of: value) { newValue in
            if newValue < range.lowerBound { value = range.lowerBound }
            if newValue > range.upperBound { value = range.upperBound }
        }
    }
}
