import SwiftUI

/// Root content view: tab bar + launch toolbar + terminal sessions + status bar.
struct MainWindow: View {
    @StateObject private var tabManager = TabManager()
    @State private var showSettings = false
    @State private var windowTitle: String = "ClaudyBro"

    var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                TabBarView(tabManager: tabManager)
            }

            if let tab = tabManager.activeTab {
                LaunchToolbar(
                    processManager: tab.processManager,
                    processMonitor: tab.processMonitor
                )
            }

            ZStack {
                ForEach(tabManager.tabs) { tab in
                    TerminalViewWrapper(
                        processManager: tab.processManager,
                        processMonitor: tab.processMonitor,
                        isActive: tab.id == tabManager.activeTabId
                    )
                    .opacity(tab.id == tabManager.activeTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.activeTabId)
                }
            }

            if let tab = tabManager.activeTab {
                StatusBarView(
                    processMonitor: tab.processMonitor,
                    shellPID: tab.processManager.shellPID
                )
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: Constants.backgroundColor))
        .preferredColorScheme(.dark)
        .navigationTitle(windowTitle)
        .onAppear { AppDelegate.tabManager = tabManager }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
            tabManager.addNewTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            if let id = tabManager.activeTabId { tabManager.requestCloseTab(id: id) }
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
        let dir = tab.processMonitor.currentDirectory
        guard !dir.isEmpty else { windowTitle = "ClaudyBro"; return }
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
        .background(Color(nsColor: Constants.statusBarBackground))
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
        NotificationCenter.default.post(
            name: .sendTerminalCommand, object: nil,
            userInfo: ["command": command]
        )
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject private var config = AppConfiguration.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Appearance") {
                Stepper("Font Size: \(Int(config.fontSize))", value: $config.fontSize, in: 8...32, step: 1)
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
            Section("Process Monitor") {
                Stepper("Auto-kill orphans after: \(config.autoKillTimeoutSeconds)s",
                        value: $config.autoKillTimeoutSeconds, in: 0...600, step: 10)
                Stepper("Orphan timeout: \(config.orphanTimeoutSeconds)s",
                        value: $config.orphanTimeoutSeconds, in: 5...300, step: 5)
                Stepper("Monitor interval: \(config.processMonitorInterval)s",
                        value: $config.processMonitorInterval, in: 1...30, step: 1)
                Toggle("MCP standby mode", isOn: $config.mcpStandbyEnabled)
                if config.mcpStandbyEnabled {
                    Stepper("Standby after idle: \(config.mcpStandbyIdleSeconds)s",
                            value: $config.mcpStandbyIdleSeconds, in: 30...600, step: 30)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 320)
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
