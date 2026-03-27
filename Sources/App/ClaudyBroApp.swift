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
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared reference set by MainWindow so we can check for running CLI sessions.
    static weak var tabManager: TabManager?

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
}
