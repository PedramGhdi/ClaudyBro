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

        // Kill every pane's shell tree via its process group.
        // SwiftUI doesn't release the NSView deterministically, so relying on
        // deinit leaks zsh + CLI trees as children of ClaudyBro forever.
        for pane in tab.root.allLeaves {
            let shellPID = pane.processManager.shellPID
            if shellPID > 0 {
                pane.processMonitor.stopMonitoring()
                kill(-shellPID, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if ProcessTreeQuery.isProcessAlive(shellPID) { kill(-shellPID, SIGKILL) }
                }
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

/// One terminal *tab* — owns a recursive pane tree. The active pane within
/// a tab is what the toolbar / status bar / keyboard shortcuts target.
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String = "Shell"
    @Published var root: PaneNode
    @Published var activePaneId: UUID

    init(initialDirectory: String? = nil) {
        let firstLeaf = PaneNode.leaf(initialDirectory: initialDirectory)
        self.root = firstLeaf
        self.activePaneId = firstLeaf.leafPane!.id
    }

    /// Convenience for the first leaf — used during init / fallbacks.
    var firstLeaf: TerminalPane { root.allLeaves.first! }

    /// Currently focused pane. Falls back to the first leaf if id is stale.
    var activePane: TerminalPane {
        root.allLeaves.first { $0.id == activePaneId } ?? firstLeaf
    }

    /// True if any pane in this tab has an active CLI session.
    var hasAnyCLIRunning: Bool { root.allLeaves.contains { $0.hasAnyCLIRunning } }

    /// CLI of the currently active pane (drives toolbar / window title).
    var runningCLI: CLIProvider? { activePane.runningCLI }

    // MARK: - Pane operations

    func splitActivePane(direction: SplitDirection) {
        if let newId = root.split(leafId: activePaneId, direction: direction) {
            activePaneId = newId
        }
    }

    /// Close the active pane. Returns true if the tab itself should close
    /// (because the tree is now empty).
    @discardableResult
    func closeActivePane() -> Bool {
        let leaves = root.allLeaves
        // Last leaf in this tab — caller should close the whole tab.
        if leaves.count <= 1 { return true }

        // Kill the pane's shell tree before removing it.
        let pane = activePane
        let shellPID = pane.processManager.shellPID
        if shellPID > 0 {
            pane.processMonitor.stopMonitoring()
            kill(-shellPID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if ProcessTreeQuery.isProcessAlive(shellPID) { kill(-shellPID, SIGKILL) }
            }
        }

        let removedId = pane.id
        if let nextId = root.removeLeaf(id: removedId) {
            activePaneId = nextId
        }
        return false
    }

    func focusNextPane() {
        let leaves = root.allLeaves
        guard leaves.count > 1,
              let idx = leaves.firstIndex(where: { $0.id == activePaneId }) else { return }
        activePaneId = leaves[(idx + 1) % leaves.count].id
    }
}
