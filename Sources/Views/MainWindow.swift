import SwiftUI

/// Root content view: tab bar + launch toolbar + terminal sessions + status bar.
struct MainWindow: View {
    @StateObject private var tabManager = TabManager()
    @State private var showSettings = false

    private var windowTitle: String {
        guard let tab = tabManager.activeTab else { return "ClaudyBro" }
        let dir = tab.processMonitor.currentDirectory
        guard !dir.isEmpty else { return "ClaudyBro" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        return abbreviated
    }

    var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                TabBarView(tabManager: tabManager)
            }

            if let tab = tabManager.activeTab {
                LaunchToolbar(
                    claudeFound: tab.processManager.claudeFound,
                    currentPath: tab.processMonitor.currentDirectory
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

            if let tab = tabManager.activeTab,
               tab.processMonitor.hasActiveProcesses
                || !tab.processMonitor.orphanedProcesses.isEmpty
            {
                StatusBarView(
                    processMonitor: tab.processMonitor,
                    claudePID: tab.processManager.claudePID
                )
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: Constants.backgroundColor))
        .preferredColorScheme(.dark)
        .navigationTitle(windowTitle)
        .onAppear { AppDelegate.tabManager = tabManager }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
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
    }
}

// MARK: - Launch Toolbar

struct LaunchToolbar: View {
    let claudeFound: Bool
    let currentPath: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(claudeFound ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            // Show current directory path (abbreviated)
            Text(abbreviatedPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: Constants.statusTextColor))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            Button(action: { runClaude(skipPermissions: false) }) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text("Run Claude").font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(nsColor: Constants.accentColor))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)

            Button(action: { runClaude(skipPermissions: true) }) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text("Skip Permissions").font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.8))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 28)
        .background(Color(nsColor: Constants.statusBarBackground))
    }

    private var abbreviatedPath: String {
        guard !currentPath.isEmpty else {
            return claudeFound ? "Claude CLI found" : "Claude CLI not in PATH"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentPath.hasPrefix(home) {
            return "~" + currentPath.dropFirst(home.count)
        }
        return currentPath
    }

    private func runClaude(skipPermissions: Bool) {
        var command = "claude"
        if skipPermissions { command += " --dangerously-skip-permissions" }
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
            Section("Claude") {
                HStack {
                    Text("Binary Path")
                    Spacer()
                    TextField("auto", text: $config.claudePath)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Section("Process Monitor") {
                Toggle("Auto-clean orphaned processes", isOn: $config.autoCleanOrphans)
                Stepper("Orphan timeout: \(config.orphanTimeoutSeconds)s",
                        value: $config.orphanTimeoutSeconds, in: 5...300, step: 5)
                Stepper("Monitor interval: \(config.processMonitorInterval)s",
                        value: $config.processMonitorInterval, in: 1...30, step: 1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 320)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { config.save(); dismiss() }
            }
        }
    }
}
