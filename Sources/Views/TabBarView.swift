import SwiftUI

/// macOS-style tab strip for terminal sessions.
struct TabBarView: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabManager.tabs) { tab in
                TabItem(
                    title: tab.title,
                    isActive: tab.id == tabManager.activeTabId,
                    canClose: tabManager.tabs.count > 1,
                    onSelect: { tabManager.selectTab(id: tab.id) },
                    onClose: { tabManager.requestCloseTab(id: tab.id) }
                )
            }

            // New tab (+) button
            Button(action: { tabManager.addNewTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: Constants.statusTextColor))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("New Tab (Cmd+T)")

            Spacer()
        }
        .frame(height: 28)
        .background(Color(nsColor: Constants.statusBarBackground))
    }
}

// MARK: - Single Tab Item

private struct TabItem: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))

            Text(title)
                .font(.system(size: 11, weight: isActive ? .medium : .regular, design: .monospaced))
                .lineLimit(1)

            if canClose && (isActive || isHovered) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                        .background(
                            Circle()
                                .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
                        )
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .foregroundColor(isActive ? .white : Color(nsColor: Constants.statusTextColor))
        .background(tabBackground)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundColor(isActive ? Color(nsColor: Constants.accentColor) : .clear),
            alignment: .bottom
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isActive {
            Color(nsColor: Constants.backgroundColor)
        } else if isHovered {
            Color.white.opacity(0.05)
        } else {
            Color.clear
        }
    }
}
