import SwiftUI

/// Root content view: tab bar + launch toolbar + terminal sessions + status bar.
struct MainWindow: View {
    @StateObject private var tabManager = TabManager()
    @State private var showSettings = false
    @State private var showCommandPalette = false
    @State private var windowTitle: String = "ClaudyBro"

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
        .background(Color(nsColor: AppConfiguration.shared.currentTheme.background))
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
        let dir = tab.activePane.processMonitor.currentDirectory
        guard !dir.isEmpty else { windowTitle = "ClaudyBro"; return }
        // Keep lastWorkingDirectory fresh so app restart uses the latest cwd
        UserDefaults.standard.set(dir, forKey: "lastWorkingDirectory")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        if abbreviated != windowTitle { windowTitle = abbreviated }
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

        // If a CLI is already running, kill it first (Ctrl+C), then launch the new one
        let keywords = CLIProvider.allCases.map(\.processKeyword)
        let cliRunning = processMonitor.childProcesses.contains { proc in
            let desc = proc.processDescription.lowercased()
            return keywords.contains { desc.contains($0) }
        }
        if cliRunning {
            // Kill the running CLI process and wait for it to exit before launching new one
            var cliPids: [pid_t] = []
            for proc in processMonitor.childProcesses {
                let desc = proc.processDescription.lowercased()
                if keywords.contains(where: { desc.contains($0) }) {
                    kill(proc.pid, SIGTERM)
                    cliPids.append(proc.pid)
                }
            }
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

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $config.theme) {
                    ForEach(Theme.allPresets) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Stepper("Font Size: \(Int(config.fontSize))", value: $config.fontSize, in: 8...32, step: 1)
                HStack {
                    Text("Font Family")
                    Spacer()
                    TextField("SF Mono", text: $config.fontName)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Any installed monospaced font (e.g., \"Menlo\", \"JetBrains Mono\"). Falls back to system mono if invalid.")
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
            Section("Terminal") {
                Toggle("Full scrollback (disable alternate screen)", isOn: $config.disableAltScreen)
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
                StepperField(label: "Auto-kill orphans after:",
                             value: $config.autoKillTimeoutSeconds, range: 0...600, step: 10)
                Text("0s = kill immediately once an orphan is confirmed")
                    .font(.caption).foregroundColor(.secondary)
                StepperField(label: "Orphan timeout:",
                             value: $config.orphanTimeoutSeconds, range: 5...300, step: 5)
                StepperField(label: "Monitor interval:",
                             value: $config.processMonitorInterval, range: 1...30, step: 1)
                StepperField(label: "Kill idle MCP servers after:",
                             value: $config.mcpIdleKillSeconds, range: 0...600, step: 30)
                Text("Kills idle MCPs under CLIs that auto-restart them (e.g. Claude). For other CLIs, the entire CLI subtree is protected. 0s = kill as soon as idle.")
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
