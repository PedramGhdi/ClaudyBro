import AppKit
import SwiftTerm
import SwiftUI

/// Bridges SwiftTerm's LocalProcessTerminalView into SwiftUI.
struct TerminalViewWrapper: NSViewRepresentable {
    @ObservedObject var processManager: CLIProcessManager
    @ObservedObject var processMonitor: ProcessMonitor
    var isActive: Bool
    var initialDirectory: String?

    func makeNSView(context: Context) -> ClaudyTerminalView {
        let terminalView = ClaudyTerminalView(frame: .zero)
        terminalView.configureAppearance()
        terminalView.isActiveTab = isActive

        let (executable, args, env) = processManager.resolveShellCommand()
        let startDir = initialDirectory
            ?? UserDefaults.standard.string(forKey: "lastWorkingDirectory")
        terminalView.startProcess(
            executable: executable, args: args, environment: env,
            currentDirectory: startDir
        )

        // Use SwiftTerm's shellPid directly — reliable, no guessing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            [weak terminalView, weak processManager, weak processMonitor] in
            guard let tv = terminalView, let pm = processManager else { return }
            let pid = tv.process.shellPid
            guard pid > 0 else { return }
            pm.shellPID = pid
            pm.isRunning = true
            processMonitor?.startMonitoring(shellPID: pid)
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

// MARK: - LinkSanitizingDelegate

/// Proxy delegate that intercepts `requestOpenLink` to sanitize URLs before opening.
/// Necessary because the default implementation lives in a protocol extension (static dispatch),
/// so a subclass of LocalProcessTerminalView cannot override it.
private final class LinkSanitizingDelegate: TerminalViewDelegate {
    weak var original: (any TerminalViewDelegate)?

    init(original: any TerminalViewDelegate) {
        self.original = original
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If link already has a scheme (e.g. https://..., mailto:...), use as-is
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") {
            if let url = URL(string: trimmed) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // Bare hostname like "github.com/user/repo" → prepend https://
        if let url = URL(string: "https://" + trimmed) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Forwarded delegate methods

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        original?.send(source: source, data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        original?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        original?.setTerminalTitle(source: source, title: title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        original?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func scrolled(source: TerminalView, position: Double) {
        original?.scrolled(source: source, position: position)
    }
    func bell(source: TerminalView) {
        original?.bell(source: source)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        original?.clipboardCopy(source: source, content: content)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        original?.iTermContent(source: source, content: content)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        original?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}

// MARK: - ClaudyTerminalView

final class ClaudyTerminalView: LocalProcessTerminalView {
    var isActiveTab: Bool = false
    private var keyMonitor: Any?
    private var linkDelegate: LinkSanitizingDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        // Install URL-sanitizing delegate proxy (must be after super.init which sets terminalDelegate = self)
        let proxy = LinkSanitizingDelegate(original: self)
        self.linkDelegate = proxy
        self.terminalDelegate = proxy

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTerminalCommand(_:)),
            name: .sendTerminalCommand, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWorkingDirectory),
            name: NSApplication.willTerminateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCLIExited(_:)),
            name: .cliProcessExited, object: nil
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

    /// Reset terminal modes that AI CLIs may have enabled but not cleaned up (e.g., Ctrl+C exit).
    @objc private func handleCLIExited(_ notification: Notification) {
        guard let shellPid = notification.userInfo?["shellPid"] as? pid_t,
              shellPid == self.process?.shellPid,
              shellPid > 0
        else { return }

        let terminal = getTerminal()

        // Pop all Kitty keyboard protocol levels — prevents raw escape sequences for arrow keys
        if terminal.keyboardEnhancementFlags != [] {
            feed(text: "\u{1b}[<99u")
        }

        // Disable bracketed paste mode
        if terminal.bracketedPasteMode {
            feed(text: "\u{1b}[?2004l")
        }

        // Disable application cursor mode
        if terminal.applicationCursor {
            feed(text: "\u{1b}[?1l")
        }
    }

    @objc private func saveWorkingDirectory() {
        guard isActiveTab else { return }
        let pid = self.process.shellPid
        guard pid > 0,
              let cwd = ProcessTreeQuery.getProcessCurrentDirectory(pid: pid),
              !cwd.isEmpty
        else { return }
        UserDefaults.standard.set(cwd, forKey: "lastWorkingDirectory")
    }

    // MARK: - Scroll Position Preservation

    private var suppressScrollerUpdate = false

    /// Suppress scroller updates while we restore scroll position to prevent flicker.
    override func scrolled(source: Terminal, yDisp: Int) {
        guard !suppressScrollerUpdate else { return }
        super.scrolled(source: source, yDisp: yDisp)
    }

    /// Preserve scroll position and text selection while new output streams in.
    /// SwiftTerm's macOS backend never sets `userScrolling`, so Terminal always
    /// snaps yDisp to yBase on new output. We save/restore yDisp around feed.
    /// Also prevents feedPrepare() from clearing active text selection.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let wasScrolledUp = canScroll && scrollPosition < 1.0
        let savedYDisp = getTerminal().buffer.yDisp

        // Prevent feedPrepare() from clearing text selection during output
        let savedMouseReporting = allowMouseReporting
        allowMouseReporting = false

        if wasScrolledUp { suppressScrollerUpdate = true }

        super.dataReceived(slice: slice)

        allowMouseReporting = savedMouseReporting

        if wasScrolledUp {
            getTerminal().buffer.yDisp = savedYDisp
            suppressScrollerUpdate = false
            // Trigger scroller update with restored position
            super.scrolled(source: getTerminal(), yDisp: savedYDisp)
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

    // macOS keyCodes for arrow/navigation keys that macOS erroneously marks with .numericPad
    private static let functionKeyCodes: Set<UInt16> = [
        123, 124, 125, 126,  // Left, Right, Down, Up
        115, 119, 116, 121,  // Home, End, PageUp, PageDown
        117,                  // Forward Delete
    ]

    /// Strip .numericPad from navigation keys so SwiftTerm encodes them as regular arrows
    /// (CSI A/B/C/D) instead of keypad variants (CSI 57419-57424 u) in Kitty keyboard mode.
    private static func fixNumericPadFlag(_ event: NSEvent) -> NSEvent {
        guard functionKeyCodes.contains(event.keyCode),
              event.modifierFlags.contains(.numericPad)
        else { return event }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.numericPad),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActiveTab else { return event }

            // Fix macOS quirk: regular arrow/nav keys have .numericPad flag, causing
            // SwiftTerm to encode them as keypad variants in Kitty keyboard protocol.
            let event = Self.fixNumericPadFlag(event)
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
