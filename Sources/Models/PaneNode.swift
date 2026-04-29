import Foundation

enum SplitDirection {
    case vertical    // side-by-side (HSplitView)
    case horizontal  // stacked      (VSplitView)
}

/// One terminal session inside a split. Owns its shell + process bookkeeping.
final class TerminalPane: Identifiable, ObservableObject {
    let id = UUID()
    let processManager = CLIProcessManager()
    let processMonitor: ProcessMonitor
    let initialDirectory: String?

    init(initialDirectory: String?) {
        self.initialDirectory = initialDirectory
        let monitor = ProcessMonitor()
        let config = AppConfiguration.shared
        monitor.monitorInterval = TimeInterval(config.processMonitorInterval)
        monitor.orphanTimeout = TimeInterval(config.orphanTimeoutSeconds)
        monitor.autoKillTimeout = TimeInterval(config.autoKillTimeoutSeconds)
        monitor.mcpIdleTimeout = TimeInterval(config.mcpIdleKillSeconds)
        self.processMonitor = monitor
    }

    var hasAnyCLIRunning: Bool { processMonitor.activeCLI != nil }
    var runningCLI: CLIProvider? { processMonitor.activeCLI }
}

/// Recursive pane tree: a node is either a leaf (one terminal) or a split
/// containing child nodes laid out in a fixed direction.
final class PaneNode: Identifiable, ObservableObject {
    let id = UUID()
    @Published var content: Content

    enum Content {
        case leaf(TerminalPane)
        case split(SplitDirection, [PaneNode])
    }

    init(_ content: Content) { self.content = content }

    static func leaf(initialDirectory: String? = nil) -> PaneNode {
        PaneNode(.leaf(TerminalPane(initialDirectory: initialDirectory)))
    }

    var leafPane: TerminalPane? {
        if case .leaf(let pane) = content { return pane }
        return nil
    }

    /// All leaf panes in left-to-right / top-to-bottom traversal order.
    var allLeaves: [TerminalPane] {
        switch content {
        case .leaf(let pane): return [pane]
        case .split(_, let children): return children.flatMap { $0.allLeaves }
        }
    }

    /// Find the parent split node containing the given leaf id, plus its index.
    /// Returns nil if the leaf is the root or absent.
    func findParent(of leafId: UUID) -> (parent: PaneNode, indexInParent: Int)? {
        guard case .split(_, let children) = content else { return nil }
        for (i, child) in children.enumerated() {
            if case .leaf(let pane) = child.content, pane.id == leafId {
                return (self, i)
            }
            if let inner = child.findParent(of: leafId) { return inner }
        }
        return nil
    }

    /// Find the path from root to the leaf with this id (each entry: node + child index).
    /// Used for in-place tree mutation.
    func findLeafNode(id: UUID) -> PaneNode? {
        switch content {
        case .leaf(let pane): return pane.id == id ? self : nil
        case .split(_, let children):
            for child in children {
                if let found = child.findLeafNode(id: id) { return found }
            }
            return nil
        }
    }

    /// Replace the leaf with the given id by splitting it: keep the original
    /// pane and add a fresh sibling pane in the requested direction.
    /// Returns the new sibling pane's id (so callers can focus it).
    @discardableResult
    func split(leafId: UUID, direction: SplitDirection) -> UUID? {
        guard let leafNode = findLeafNode(id: leafId),
              case .leaf(let existingPane) = leafNode.content
        else { return nil }

        let newPane = TerminalPane(initialDirectory: existingPane.processMonitor.currentDirectory.isEmpty
            ? existingPane.initialDirectory
            : existingPane.processMonitor.currentDirectory)
        let keepNode = PaneNode(.leaf(existingPane))
        let newNode = PaneNode(.leaf(newPane))
        leafNode.content = .split(direction, [keepNode, newNode])
        return newPane.id
    }

    /// Remove the leaf with the given id. Collapses single-child splits.
    /// Returns the id of a leaf to focus next, or nil if the tree is now empty.
    @discardableResult
    func removeLeaf(id: UUID) -> UUID? {
        // Special case: root is the leaf — caller handles tab close.
        if case .leaf(let pane) = content, pane.id == id { return nil }
        _ = removeLeafRecursive(id: id, in: self)
        collapseSingletons(self)
        return allLeaves.first?.id
    }

    private func removeLeafRecursive(id: UUID, in node: PaneNode) -> Bool {
        guard case .split(let dir, var children) = node.content else { return false }
        if let idx = children.firstIndex(where: {
            if case .leaf(let p) = $0.content { return p.id == id }
            return false
        }) {
            children.remove(at: idx)
            node.content = .split(dir, children)
            return true
        }
        for child in children {
            if removeLeafRecursive(id: id, in: child) { return true }
        }
        return false
    }

    /// If a split has only one child, replace it with that child's content.
    /// Recurses bottom-up.
    private func collapseSingletons(_ node: PaneNode) {
        guard case .split(_, let children) = node.content else { return }
        for child in children { collapseSingletons(child) }
        if case .split(_, let updated) = node.content, updated.count == 1 {
            node.content = updated[0].content
        }
    }
}
