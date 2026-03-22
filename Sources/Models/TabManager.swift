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

    /// True if any tab has Claude running.
    var hasAnyClaudeRunning: Bool {
        tabs.contains { $0.hasClaudeRunning }
    }

    func addNewTab() {
        let tab = TerminalTab()
        tabs.append(tab)
        activeTabId = tab.id
    }

    /// Close a tab — shows confirmation if Claude is running.
    func requestCloseTab(id: UUID) {
        guard tabs.count > 1 else { return }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }

        if tab.hasClaudeRunning {
            let confirmed = showCloseConfirmation(
                message: "Claude is running in this tab.",
                info: "Closing will terminate the Claude session. Are you sure?"
            )
            guard confirmed else { return }
        }

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

    /// Confirm before quitting the app if Claude is running. Returns true if OK to quit.
    func confirmQuitIfNeeded() -> Bool {
        guard hasAnyClaudeRunning else { return true }

        let runningCount = tabs.filter { $0.hasClaudeRunning }.count
        let tabWord = runningCount == 1 ? "tab" : "tabs"

        return showCloseConfirmation(
            message: "Claude is running in \(runningCount) \(tabWord).",
            info: "Quitting will terminate all Claude sessions. Are you sure?"
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
    let processManager = ClaudeProcessManager()
    let processMonitor = ProcessMonitor()

    /// Check if a "claude" process is running in this tab's process tree.
    var hasClaudeRunning: Bool {
        let pid = processManager.claudePID
        guard pid > 0 else { return false }
        let descendants = ProcessTreeQuery.getDescendantProcesses(of: pid)
        return descendants.contains { $0.name.contains("claude") }
    }
}
