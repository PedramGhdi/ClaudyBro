import SwiftUI

/// Cmd+Shift+P fuzzy command palette. Each entry posts an existing notification
/// so the dispatch surface stays unified with menu commands and shortcuts.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let providers: [CLIProvider]
    let installedProviders: Set<CLIProvider>
    let npxAvailable: Bool

    @ObservedObject private var config = AppConfiguration.shared
    @State private var query: String = ""
    @State private var highlighted: Int = 0
    @FocusState private var fieldFocused: Bool

    struct Command: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let systemImage: String
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 520)
        .background(KeyHandler(
            onUp: { highlighted = max(0, highlighted - 1) },
            onDown: { highlighted = min(max(filtered.count - 1, 0), highlighted + 1) },
            onEscape: { isPresented = false }
        ))
        .onAppear {
            fieldFocused = true
            highlighted = 0
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit(runHighlighted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onChange(of: query) { _ in highlighted = 0 }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cmd in
                        CommandRow(cmd: cmd, isHighlighted: idx == highlighted)
                            .id(idx)
                            .onTapGesture { runCommand(cmd) }
                            .onHover { if $0 { highlighted = idx } }
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: highlighted) { idx in
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    // MARK: - Command list

    private var commands: [Command] {
        var list: [Command] = []
        list.append(contentsOf: providerCommands())
        list.append(contentsOf: promptCommands())
        list.append(contentsOf: appActionCommands())
        list.append(contentsOf: themeCommands())
        return list
    }

    private func providerCommands() -> [Command] {
        var out: [Command] = []
        for provider in providers {
            let installed = installedProviders.contains(provider)
            let canRun = installed || (npxAvailable && provider.npxPackage != nil)
            guard canRun else { continue }
            let prefix = installed ? "Run" : "npx"
            out.append(Command(
                title: "\(prefix) \(provider.displayName)",
                subtitle: installed ? nil : "via npx",
                systemImage: provider.iconName,
                action: { runProvider(provider, dangerous: false, viaNpx: !installed) }
            ))
            if installed, let label = provider.dangerousButtonLabel {
                out.append(Command(
                    title: "\(provider.displayName) — \(label)",
                    subtitle: nil,
                    systemImage: "bolt.fill",
                    action: { runProvider(provider, dangerous: true, viaNpx: false) }
                ))
            }
        }
        return out
    }

    private func promptCommands() -> [Command] {
        config.savedPrompts.map { prompt in
            Command(
                title: prompt.name,
                subtitle: "Saved prompt",
                systemImage: "text.bubble",
                action: { sendCommand(prompt.body + "\n") }
            )
        }
    }

    private func appActionCommands() -> [Command] {
        [
            Command(title: "New Tab", subtitle: "⌘T", systemImage: "plus.square",
                    action: { post(.newTab) }),
            Command(title: "Close Tab", subtitle: "⌘W", systemImage: "xmark.square",
                    action: { post(.closeTab) }),
            Command(title: "Split Vertically", subtitle: "⌘D", systemImage: "rectangle.split.2x1",
                    action: { post(.splitPaneVertical) }),
            Command(title: "Split Horizontally", subtitle: "⌘⇧D", systemImage: "rectangle.split.1x2",
                    action: { post(.splitPaneHorizontal) }),
            Command(title: "Close Pane", subtitle: "⌘⇧W", systemImage: "rectangle.badge.minus",
                    action: { post(.closePane) }),
            Command(title: "Next Pane", subtitle: "⌘⌥]", systemImage: "rectangle.on.rectangle",
                    action: { post(.nextPane) }),
            Command(title: "Kill Orphaned Processes", subtitle: "⌘⇧K", systemImage: "trash",
                    action: { post(.killOrphanProcesses) }),
            Command(title: "Settings…", subtitle: "⌘,", systemImage: "gearshape",
                    action: { post(.openSettings) }),
            Command(title: "Check for Updates", subtitle: nil, systemImage: "arrow.down.circle",
                    action: { UpdateChecker.shared.checkForUpdates() }),
        ]
    }

    private func themeCommands() -> [Command] {
        Theme.allPresets.map { theme in
            Command(
                title: "Theme: \(theme.name)",
                subtitle: theme.id == config.theme ? "active" : nil,
                systemImage: "paintpalette",
                action: { applyTheme(theme.id) }
            )
        }
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { cmd in
            fuzzyMatch(needle: q, haystack: cmd.title.lowercased())
                || (cmd.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Actions

    private func runHighlighted() {
        guard !filtered.isEmpty else { return }
        let idx = max(0, min(highlighted, filtered.count - 1))
        runCommand(filtered[idx])
    }

    private func runCommand(_ cmd: Command) {
        isPresented = false
        DispatchQueue.main.async { cmd.action() }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func sendCommand(_ text: String) {
        NotificationCenter.default.post(
            name: .sendTerminalCommand, object: nil,
            userInfo: ["command": text]
        )
    }

    private func applyTheme(_ id: String) {
        config.theme = id
        config.save()
        post(.configurationChanged)
    }

    private func runProvider(_ provider: CLIProvider, dangerous: Bool, viaNpx: Bool) {
        config.preferredCLI = provider.rawValue
        config.preferredDangerousMode = dangerous
        config.save()

        let cmd: String
        if viaNpx {
            cmd = provider.npxLaunchCommand ?? provider.launchCommand
        } else if dangerous {
            cmd = provider.dangerousLaunchCommand ?? provider.launchCommand
        } else {
            cmd = provider.launchCommand
        }
        sendCommand(cmd + "\n")
    }

    /// Subsequence fuzzy match.
    private func fuzzyMatch(needle: String, haystack: String) -> Bool {
        var hi = haystack.startIndex
        for n in needle {
            guard let found = haystack[hi...].firstIndex(of: n) else { return false }
            hi = haystack.index(after: found)
        }
        return true
    }
}

private struct CommandRow: View {
    let cmd: CommandPaletteView.Command
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 22)
            Text(cmd.title)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
            if let subtitle = cmd.subtitle {
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct KeyHandler: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onUp = onUp
        v.onDown = onDown
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onEscape = onEscape
    }

    final class KeyView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.window != nil else { return event }
                    switch event.keyCode {
                    case 126: self.onUp?(); return nil
                    case 125: self.onDown?(); return nil
                    case 53:  self.onEscape?(); return nil
                    default: return event
                    }
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
