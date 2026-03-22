import AppKit
import SwiftTerm
import SwiftUI

/// Bridges SwiftTerm's LocalProcessTerminalView into SwiftUI.
struct TerminalViewWrapper: NSViewRepresentable {
    @ObservedObject var processManager: ClaudeProcessManager
    @ObservedObject var processMonitor: ProcessMonitor
    var isActive: Bool

    func makeNSView(context: Context) -> ClaudyTerminalView {
        let terminalView = ClaudyTerminalView(frame: .zero)
        terminalView.configureAppearance()
        terminalView.isActiveTab = isActive

        let (executable, args, env) = processManager.resolveShellCommand()
        let lastDir = UserDefaults.standard.string(forKey: "lastWorkingDirectory")
        terminalView.startProcess(
            executable: executable, args: args, environment: env,
            currentDirectory: lastDir
        )

        // One-shot shell PID discovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            [weak processManager, weak processMonitor] in
            guard let pm = processManager else { return }
            let appPID = ProcessInfo.processInfo.processIdentifier
            let children = ProcessTreeQuery.getChildProcesses(of: appPID)
            if let shell = children.last {
                pm.claudePID = shell.pid
                pm.isRunning = true
                processMonitor?.startMonitoring(claudePID: shell.pid)
            }
        }

        return terminalView
    }

    func updateNSView(_ nsView: ClaudyTerminalView, context: Context) {
        let wasActive = nsView.isActiveTab
        nsView.isActiveTab = isActive
        if isActive && !wasActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - ClaudyTerminalView

final class ClaudyTerminalView: LocalProcessTerminalView {
    var isActiveTab: Bool = false
    private var keyMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTerminalCommand(_:)),
            name: .sendTerminalCommand, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWorkingDirectory),
            name: NSApplication.willTerminateNotification, object: nil
        )

        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Commands & State

    @objc private func handleTerminalCommand(_ notification: Notification) {
        guard isActiveTab, let cmd = notification.userInfo?["command"] as? String else { return }
        send(txt: cmd)
    }

    @objc private func saveWorkingDirectory() {
        guard isActiveTab else { return }
        let appPID = ProcessInfo.processInfo.processIdentifier
        for child in ProcessTreeQuery.getChildProcesses(of: appPID) {
            if let cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: child.pid) {
                UserDefaults.standard.set(cwd, forKey: "lastWorkingDirectory")
                return
            }
        }
    }

    func configureAppearance() {
        let config = AppConfiguration.shared
        font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        nativeForegroundColor = Constants.foregroundColor
        nativeBackgroundColor = Constants.backgroundColor
        changeScrollback(5000)
        getTerminal().options.kittyImageCacheLimitBytes = 1_000_000
        getTerminal().options.enableSixelReported = false
    }

    // MARK: - Focus management

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isActiveTab, window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isActiveTab else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    // MARK: - Keyboard Shortcuts (Cmd+ only)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActiveTab else { return false }

        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch chars {
        case "w": // Intercept Cmd+W to prevent default window close
            NotificationCenter.default.post(name: .closeTab, object: nil)
            return true
        case "k" where event.modifierFlags.contains(.shift):
            NotificationCenter.default.post(name: .killOrphanProcesses, object: nil)
            return true
        case "k":
            send(txt: "\u{0C}")
            return true
        case "\u{7F}": // Cmd+Delete → kill entire line (Ctrl+U)
            send(txt: "\u{15}")
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActiveTab else { return event }

            let flags = event.modifierFlags

            // Cmd+Arrow keys → Home/End
            if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option) {
                if event.keyCode == 123 { // Cmd+Left → Home (Ctrl+A)
                    self.send(txt: "\u{01}")
                    return nil
                }
                if event.keyCode == 124 { // Cmd+Right → End (Ctrl+E)
                    self.send(txt: "\u{05}")
                    return nil
                }
            }

            // Shift+Enter → newline (not submit)
            if event.keyCode == 36, flags.contains(.shift),
               !flags.contains(.command) {
                self.send(txt: "\u{1B}[13;2u")
                return nil
            }

            // Option+Delete → delete word backward (Ctrl+W)
            if event.keyCode == 51, flags.contains(.option),
               !flags.contains(.command) {
                self.send(txt: "\u{17}")
                return nil
            }

            return event
        }
    }

    // MARK: - Drag & Drop (accepts any file, inserts path)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty
        else { return false }

        // Quote paths that contain spaces, join multiple with space
        let paths = urls.map { url -> String in
            let path = url.path
            return path.contains(" ") ? "'\(path)'" : path
        }
        send(txt: paths.joined(separator: " "))
        return true
    }
}
