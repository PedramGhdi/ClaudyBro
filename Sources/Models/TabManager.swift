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

    func addNewTab(initialDirectory: String? = nil) {
        let tab = TerminalTab(initialDirectory: initialDirectory)
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
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let wasActive = (id == activeTabId)
        let idx = tabs.firstIndex { $0.id == id } ?? 0

        // Kill the tab's shell + all descendants via its process group.
        // SwiftUI doesn't release the NSView deterministically, so relying on
        // deinit leaks zsh + CLI trees as children of ClaudyBro forever.
        let shellPID = tab.processManager.shellPID
        if shellPID > 0 {
            tab.processMonitor.stopMonitoring()
            kill(-shellPID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if ProcessTreeQuery.isProcessAlive(shellPID) { kill(-shellPID, SIGKILL) }
            }
        }

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

    func moveTab(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < tabs.count,
              destination >= 0, destination < tabs.count
        else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
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
    let initialDirectory: String?

    init(initialDirectory: String? = nil) {
        self.initialDirectory = initialDirectory
        let monitor = ProcessMonitor()
        let config = AppConfiguration.shared
        monitor.monitorInterval = TimeInterval(config.processMonitorInterval)
        monitor.orphanTimeout = TimeInterval(config.orphanTimeoutSeconds)
        monitor.autoKillTimeout = TimeInterval(config.autoKillTimeoutSeconds)
        monitor.mcpIdleTimeout = TimeInterval(config.mcpIdleKillSeconds)
        self.processMonitor = monitor
    }

    /// Check if any AI CLI process is running in this tab's process tree.
    /// Reads the cached value from ProcessMonitor — never touches sysctl on the main thread.
    var hasAnyCLIRunning: Bool { runningCLI != nil }

    /// Which specific CLI is running in this tab (if any).
    /// Reads the cached value published by ProcessMonitor's background poll. This MUST
    /// NOT call sysctl — SwiftUI reads this property during view body evaluation, and a
    /// full process-tree scan here hangs the main thread once the descendant count grows
    /// (we hit this with ~60 MCP/child processes: body re-renders → sysctl → system hang).
    var runningCLI: CLIProvider? {
        processMonitor.activeCLI
    }
}
