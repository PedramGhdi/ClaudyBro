import SwiftUI

/// macOS Terminal-style tab strip for terminal sessions.
struct TabBarView: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItem(
                    processMonitor: tab.processMonitor,
                    index: index + 1,
                    isActive: tab.id == tabManager.activeTabId,
                    canClose: tabManager.tabs.count > 1,
                    onSelect: { tabManager.selectTab(id: tab.id) },
                    onClose: { tabManager.requestCloseTab(id: tab.id) }
                )

                // Separator between tabs
                if index < tabManager.tabs.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1, height: 16)
                }
            }

            // New tab (+) button
            Button(action: { tabManager.addNewTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: Constants.statusTextColor))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("New Tab (Cmd+T)")
        }
        .frame(height: 28)
        .background(Color(nsColor: Constants.statusBarBackground))
    }
}

// MARK: - Single Tab Item

private struct TabItem: View {
    @ObservedObject var processMonitor: ProcessMonitor
    let index: Int
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    private var tabTitle: String {
        let dir = processMonitor.currentDirectory
        guard !dir.isEmpty else { return "Shell" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir.hasPrefix(home) {
            return "~" + dir.dropFirst(home.count)
        }
        return dir
    }

    var body: some View {
        HStack(spacing: 0) {
            // Close button (visible on hover or active)
            if canClose && (isActive || isHovered) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .padding(.leading, 6)
            } else {
                Spacer().frame(width: 22)
            }

            Spacer(minLength: 4)

            // Tab title
            Text(tabTitle)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 4)

            // Cmd+N shortcut label
            if index <= 9 {
                Text("\u{2318}\(index)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: Constants.statusTextColor).opacity(0.6))
                    .padding(.trailing, 8)
            } else {
                Spacer().frame(width: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(isActive ? .white : Color(nsColor: Constants.statusTextColor))
        .background(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .animation(.easeInOut(duration: 0.12), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
