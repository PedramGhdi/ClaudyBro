import SwiftUI

/// Recursive renderer for one tab's pane tree. Splits use HSplitView /
/// VSplitView so users can drag the divider to resize.
struct TabPaneTreeView: View {
    @ObservedObject var tab: TerminalTab
    let isActiveTab: Bool

    var body: some View {
        PaneNodeView(node: tab.root, tab: tab, isActiveTab: isActiveTab)
    }
}

private struct PaneNodeView: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tab: TerminalTab
    let isActiveTab: Bool

    var body: some View {
        switch node.content {
        case .leaf(let pane):
            PaneLeafView(pane: pane, tab: tab, isActiveTab: isActiveTab)
        case .split(let direction, let children):
            if direction == .vertical {
                HSplitView {
                    ForEach(children) { child in
                        PaneNodeView(node: child, tab: tab, isActiveTab: isActiveTab)
                    }
                }
            } else {
                VSplitView {
                    ForEach(children) { child in
                        PaneNodeView(node: child, tab: tab, isActiveTab: isActiveTab)
                    }
                }
            }
        }
    }
}

private struct PaneLeafView: View {
    @ObservedObject var pane: TerminalPane
    @ObservedObject var tab: TerminalTab
    let isActiveTab: Bool

    var body: some View {
        let isFocused = isActiveTab && tab.activePaneId == pane.id
        ZStack(alignment: .topTrailing) {
            TerminalViewWrapper(
                processManager: pane.processManager,
                processMonitor: pane.processMonitor,
                isActive: isFocused,
                initialDirectory: pane.initialDirectory
            )
            .onTapGesture {
                if tab.activePaneId != pane.id { tab.activePaneId = pane.id }
            }

            // Subtle accent border on the focused pane (only when more than one pane exists)
            if tab.root.allLeaves.count > 1 {
                Rectangle()
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 200, minHeight: 100)
    }
}
