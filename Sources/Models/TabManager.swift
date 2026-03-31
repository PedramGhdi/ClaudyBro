import AppKit
import Foundation

/// Manages terminal tab sessions.
final class TabManager: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?

    init() {
        addNewTab()
    }

    var activeTab: TerminalTab? {
        tabs.first { $0.id == activeTabId }
    }

    var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabId } ?? 0
    }

    /// True if any tab has an AI CLI running.
    var hasAnyCLIRunning: Bool {
        tabs.contains { $0.hasAnyCLIRunning }
    }

    func addNewTab() {
        let tab = TerminalTab()
        tabs.append(tab)
        activeTabId = tab.id
    }

    /// Close a tab — always shows confirmation to prevent accidental closure.
    func requestCloseTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }

        // Last tab: confirm and quit
        if tabs.count == 1 {
            let cliName = tab.runningCLI?.displayName
            let confirmed = showCloseConfirmation(
                message: "Close ClaudyBro?",
                info: cliName != nil
                    ? "\(cliName!) is running. Closing will terminate the session."
                    : "This will close the terminal and quit the app."
            )
            if confirmed {
                NSApplication.shared.terminate(nil)
            }
            return
        }

        // Multiple tabs: always confirm
        let info: String
        if let cli = tab.runningCLI {
            info = "\(cli.displayName) is running. Closing will terminate the session."
        } else {
            info = "This will close the terminal session."
        }
        let confirmed = showCloseConfirmation(
            message: "Close this tab?",
            info: info
        )
        guard confirmed else { return }

        closeTab(id: id)
    }

    /// Close without confirmation (internal use after confirmation).
    func closeTab(id: UUID) {
        guard tabs.count > 1 else { return }
        let wasActive = (id == activeTabId)
        let idx = tabs.firstIndex { $0.id == id } ?? 0
        tabs.removeAll { $0.id == id }
        if wasActive {
            let newIdx = min(idx, tabs.count - 1)
            activeTabId = tabs[newIdx].id
        }
    }

    /// Always confirm before quitting the app. Returns true if OK to quit.
    func confirmQuitIfNeeded() -> Bool {
        let tabCount = tabs.count
        let tabWord = tabCount == 1 ? "tab" : "tabs"

        let info: String
        if hasAnyCLIRunning {
            let runningNames = Array(Set(tabs.compactMap(\.runningCLI?.displayName)))
            let cliList = runningNames.joined(separator: ", ")
            info = "\(cliList) is running. Quitting will terminate all sessions."
        } else {
            info = "This will close \(tabCount) terminal \(tabWord)."
        }

        return showCloseConfirmation(
            message: "Quit ClaudyBro?",
            info: info
        )
    }

    func selectTab(id: UUID) {
        activeTabId = id
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        let idx = (activeIndex + 1) % tabs.count
        activeTabId = tabs[idx].id
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        let idx = (activeIndex - 1 + tabs.count) % tabs.count
        activeTabId = tabs[idx].id
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabId = tabs[index].id
    }

    // MARK: - Private

    private func showCloseConfirmation(message: String, info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// One terminal session with its own shell, process manager, and monitor.
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String = "Shell"
    let processManager = CLIProcessManager()
    let processMonitor: ProcessMonitor

    init() {
        let monitor = ProcessMonitor()
        let config = AppConfiguration.shared
        monitor.monitorInterval = TimeInterval(config.processMonitorInterval)
        monitor.orphanTimeout = TimeInterval(config.orphanTimeoutSeconds)
        monitor.autoKillTimeout = TimeInterval(config.autoKillTimeoutSeconds)
        monitor.standbyEnabled = config.mcpStandbyEnabled
        monitor.standbyIdleThreshold = TimeInterval(config.mcpStandbyIdleSeconds)
        self.processMonitor = monitor
    }

    /// Check if any AI CLI process is running in this tab's process tree.
    var hasAnyCLIRunning: Bool { runningCLI != nil }

    /// Which specific CLI is running in this tab (if any).
    var runningCLI: CLIProvider? {
        let pid = processManager.shellPID
        guard pid > 0 else { return nil }
        let descendants = ProcessTreeQuery.getDescendantProcesses(of: pid)
        for provider in CLIProvider.allCases {
            if descendants.contains(where: { $0.name.contains(provider.processKeyword) }) {
                return provider
            }
        }
        return nil
    }
}
