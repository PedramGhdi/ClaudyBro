import SwiftUI

@main
struct ClaudyBroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
        .commands {
            // Cmd+, settings + Check for Updates
            CommandGroup(replacing: .appSettings) {
                Button("Check for Updates...") {
                    UpdateChecker.shared.checkForUpdates()
                }

                Divider()

                Button("Settings...") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Find. SwiftTerm ships the find bar and its search engine; it only
            // ever surfaced through the standard Edit ▸ Find menu items, which
            // this app never registered.
            CommandGroup(after: .textEditing) {
                Divider()

                Button("Find…") { AppCommands.find(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") { AppCommands.find(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") { AppCommands.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Use Selection for Find") { AppCommands.find(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)
            }

            // Tab commands
            CommandMenu("Tab") {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Next Tab") {
                    NotificationCenter.default.post(name: .nextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .previousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                // Cmd+1 through Cmd+9 for direct tab selection
                ForEach(1...9, id: \.self) { index in
                    Button("Tab \(index)") {
                        NotificationCenter.default.post(
                            name: .selectTabByIndex, object: nil,
                            userInfo: ["index": index - 1]
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
                }
            }

            // Process commands
            CommandMenu("Process") {
                Button("Kill Orphaned Processes") {
                    NotificationCenter.default.post(name: .killOrphanProcesses, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .openCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                // ⌘= is accepted as well, handled in ClaudyTerminalView — it has
                // no menu item of its own, so the two can never both fire.
                Button("Bigger Text") { AppCommands.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)

                Button("Smaller Text") { AppCommands.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") { AppCommands.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                // Needs OSC 133 marks — Settings ▸ Terminal installs the shell
                // hooks that emit them.
                Button("Previous Prompt") {
                    NotificationCenter.default.post(
                        name: .jumpToPrompt, object: nil, userInfo: ["previous": true]
                    )
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Next Prompt") {
                    NotificationCenter.default.post(
                        name: .jumpToPrompt, object: nil, userInfo: ["previous": false]
                    )
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Divider()

                Button("Split Vertically") {
                    NotificationCenter.default.post(name: .splitPaneVertical, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Split Horizontally") {
                    NotificationCenter.default.post(name: .splitPaneHorizontal, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Close Pane") {
                    NotificationCenter.default.post(name: .closePane, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("Next Pane") {
                    NotificationCenter.default.post(name: .nextPane, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])

                Toggle("Broadcast Input to All Panes", isOn: Binding(
                    get: { AppConfiguration.shared.broadcastInput },
                    set: { AppConfiguration.shared.broadcastInput = $0 }
                ))
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared reference set by MainWindow so we can check for running CLI sessions.
    static weak var tabManager: TabManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusLineBridge.ensureConfigured()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always confirm before quitting to prevent accidental closure
        if let tabManager = Self.tabManager {
            if !tabManager.confirmQuitIfNeeded() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppConfiguration.shared.restoreSession {
            Self.tabManager?.captureSession().save()
        } else {
            // Leaving a stale snapshot behind would resurrect an old layout the
            // moment the setting is switched back on.
            SessionState.clear()
        }
        try? FileManager.default.removeItem(atPath: Constants.tempDirectory)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openSettings = Notification.Name("com.claudybro.openSettings")
    static let newTab = Notification.Name("com.claudybro.newTab")
    static let closeTab = Notification.Name("com.claudybro.closeTab")
    static let nextTab = Notification.Name("com.claudybro.nextTab")
    static let previousTab = Notification.Name("com.claudybro.previousTab")
    static let selectTabByIndex = Notification.Name("com.claudybro.selectTabByIndex")
    static let openCommandPalette = Notification.Name("com.claudybro.openCommandPalette")
    static let splitPaneVertical = Notification.Name("com.claudybro.splitPaneVertical")
    static let splitPaneHorizontal = Notification.Name("com.claudybro.splitPaneHorizontal")
    static let closePane = Notification.Name("com.claudybro.closePane")
    static let nextPane = Notification.Name("com.claudybro.nextPane")
}
