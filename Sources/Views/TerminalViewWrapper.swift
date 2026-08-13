import AppKit
import SwiftTerm
import SwiftUI

/// Bridges SwiftTerm's LocalProcessTerminalView into SwiftUI.
struct TerminalViewWrapper: NSViewRepresentable {
    @ObservedObject var processManager: CLIProcessManager
    @ObservedObject var processMonitor: ProcessMonitor
    var isActive: Bool
    var initialDirectory: String?
    /// Identity used to scope broadcast input to sibling panes of one tab.
    var paneId: UUID
    var tabId: UUID

    func makeNSView(context: Context) -> ClaudyTerminalView {
        let terminalView = ClaudyTerminalView(frame: .zero)
        terminalView.configureAppearance()
        terminalView.isActiveTab = isActive
        terminalView.processMonitor = processMonitor
        terminalView.paneId = paneId
        terminalView.tabId = tabId

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

            // Create a duplicate fd for synchronous writes.
            // SwiftTerm uses DispatchIO on childfd for reads — mixing direct write()
            // calls on the same fd causes undefined behavior. A dup'd fd is a separate
            // fd number so DispatchIO isn't affected, while writes still reach the PTY.
            let masterFd = tv.process.childfd
            if masterFd >= 0 { tv.writeFd = dup(masterFd) }

            // The monitor takes its own dup so it can ask the PTY which job is
            // in the foreground — the process it must never terminate.
            processMonitor?.startMonitoring(shellPID: pid, ptyMasterFd: masterFd)

            // Startup command runs once the shell has had a moment to draw its
            // first prompt, otherwise it lands mid-initialisation and the shell
            // discards it.
            let startup = AppConfiguration.shared.startupCommand
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !startup.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak terminalView] in
                    terminalView?.send(txt: startup + "\n")
                }
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
    // Intercepted rather than forwarded. `LocalProcessTerminalView` routes both
    // of these to its `processDelegate`, which this app never assigns, so the
    // shell's title (OSC 0/1/2) and working directory (OSC 7) were being
    // discarded — tab titles came from polling the process table instead.
    func setTerminalTitle(source: TerminalView, title: String) {
        (original as? ClaudyTerminalView)?.hostDidSetTitle(title)
        original?.setTerminalTitle(source: source, title: title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        (original as? ClaudyTerminalView)?.hostDidUpdateDirectory(directory)
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
    var paneId: UUID = UUID()
    var tabId: UUID = UUID()
    weak var processMonitor: ProcessMonitor?
    private var keyMonitor: Any?
    private var linkDelegate: LinkSanitizingDelegate?
    private let altScreenFilter = AltScreenFilter()
    private var contextScanScheduled = false
    /// Duplicate fd for synchronous writes — avoids conflicting with DispatchIO on the original fd.
    var writeFd: Int32 = -1

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigurationChanged),
            name: .configurationChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJumpToPrompt(_:)),
            name: .jumpToPrompt, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBroadcastInput(_:)),
            name: .broadcastInput, object: nil
        )

        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Safety net: close the PTY so SwiftTerm's DispatchIO + fds release.
        // Without this, the shell + CLI tree survive as zombie children.
        if process?.shellPid ?? 0 > 0 { terminate() }
        if writeFd >= 0 { close(writeFd) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Synchronized PTY Writes

    /// Bypass SwiftTerm's DispatchIO.write (which races with reads on a separate GCD queue)
    /// and write synchronously to a dup'd fd. This matches Ghostty's serialized I/O model,
    /// preventing terminal responses from leaking into the shell as plaintext.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard writeToPTY(data) else {
            super.send(source: source, data: data)
            return
        }

        // Mirror input to sibling panes. Done here rather than in `keyDown`
        // because these are the exact bytes headed for the PTY — escape
        // sequences for arrows and function keys included — so the other panes
        // receive precisely what this one did, not a re-encoding of it.
        if isActiveTab, AppConfiguration.shared.broadcastInput {
            NotificationCenter.default.post(
                name: .broadcastInput, object: nil,
                userInfo: ["bytes": Array(data), "origin": paneId, "tab": tabId]
            )
        }
    }

    /// Write straight to the PTY, bypassing SwiftTerm's DispatchIO (which races
    /// with its own reads on a separate queue). Returns false if unavailable.
    @discardableResult
    private func writeToPTY(_ data: ArraySlice<UInt8>) -> Bool {
        let fd = writeFd
        guard fd >= 0 else { return false }
        data.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < ptr.count {
                let n = Darwin.write(fd, base + written, ptr.count - written)
                if n <= 0 { break }
                written += n
            }
        }
        return true
    }

    @objc private func handleBroadcastInput(_ notification: Notification) {
        guard let info = notification.userInfo,
              let bytes = info["bytes"] as? [UInt8],
              let origin = info["origin"] as? UUID,
              let tab = info["tab"] as? UUID,
              origin != paneId,        // don't echo back into the source pane
              tab == tabId             // stay within the tab the user is in
        else { return }

        writeToPTY(bytes[...])
    }

    // MARK: - Commands & State

    @objc private func handleJumpToPrompt(_ notification: Notification) {
        guard isActiveTab else { return }
        let previous = notification.userInfo?["previous"] as? Bool ?? true
        if !jumpToPrompt(previous: previous) { NSSound.beep() }
    }

    @objc private func handleTerminalCommand(_ notification: Notification) {
        guard let cmd = notification.userInfo?["command"] as? String else { return }
        // Broadcast reaches every live pane; everything else goes to the pane
        // the user is actually looking at.
        let broadcast = notification.userInfo?["broadcast"] as? Bool ?? false
        guard broadcast || isActiveTab else { return }
        send(txt: cmd)
    }

    /// Type into this terminal from outside the notification path.
    func sendText(_ text: String) { send(txt: text) }

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

        // Leave the alternate buffer if the CLI exited without doing so itself.
        if terminal.isCurrentBufferAlternate {
            feed(text: "\u{1b}[?1049l")
        }

        // The CLI is gone, so the filter must not stay latched to its state.
        altScreenFilter.reset()
        lastForegroundPgid = -1
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

    // MARK: - Context Usage Scanning

    /// Schedule a debounced scan of the terminal status line for effort/mode.
    /// Uses a simple flag to avoid allocating DispatchWorkItems on every dataReceived chunk.
    func scheduleContextScan() {
        guard !contextScanScheduled else { return }
        contextScanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.contextScanScheduled = false
            self?.scanTerminalStatusLine()
        }
    }

    /// Scan the last few terminal rows for effort/mode indicators.
    /// Context %, model, and cost come from the JSON file (read by ProcessMonitor).
    private func scanTerminalStatusLine() {
        let terminal = getTerminal()
        let rows = terminal.rows
        let scanRows = min(rows, 5)
        var lines: [String] = []
        for row in (rows - scanRows)..<rows {
            if let bufferLine = terminal.getLine(row: row) {
                let text = bufferLine.translateToString(trimRight: true)
                if !text.isEmpty { lines.append(text) }
            }
        }
        let (mode, effort) = ContextUsageParser.parseStatusLine(lines: lines)
        guard mode != nil || effort != nil else { return }

        var current = processMonitor?.contextUsage ?? ContextUsage()
        if let mode { current.modeIndicator = mode }
        if let effort { current.effort = effort }
        processMonitor?.updateContextUsage(current)
    }

    // MARK: - Prompt Navigation (OSC 133)

    /// Scroll to the previous or next shell prompt.
    ///
    /// Relies on OSC 133 marks, which a shell only emits with shell
    /// integration installed — see Settings ▸ Terminal. Without them there is
    /// nothing to jump to, so the call is a no-op rather than a guess.
    /// Returns false when no further prompt exists in that direction.
    @discardableResult
    func jumpToPrompt(previous: Bool) -> Bool {
        let terminal = getTerminal()
        let buffer = terminal.buffer

        // `bufferLine(atRow:)` is the public bounds-checked accessor: it returns
        // nil past either end, so it doubles as the loop's terminating condition.
        var row = buffer.yDisp + (previous ? -1 : 1)
        while row >= 0, terminal.bufferLine(atRow: row) != nil {
            if terminal.semanticRowKind(at: row) == .initial {
                buffer.yDisp = row
                super.scrolled(source: terminal, yDisp: row)
                needsDisplay = true
                return true
            }
            row += previous ? -1 : 1
        }
        return false
    }

    // MARK: - Copy on Select

    /// Copy the selection to the clipboard when the drag ends.
    ///
    /// Hooked to mouse-up rather than `selectionChanged`, which fires on every
    /// intermediate position during a drag — that would rewrite the pasteboard
    /// dozens of times per selection and clobber the clipboard mid-gesture.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard AppConfiguration.shared.copyOnSelect, selection.active else { return }

        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Shell-Reported Title & Directory

    /// Title set by the shell via OSC 0/1/2.
    func hostDidSetTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        processMonitor?.hostTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Working directory reported by the shell via OSC 7, as a `file://` URL.
    ///
    /// This arrives the instant the shell changes directory, where the process
    /// table is only sampled every few seconds. Remote reports are ignored: an
    /// SSH session happily emits OSC 7 for a path on the other machine, and
    /// inheriting that into a new local tab would land it somewhere that does
    /// not exist here.
    func hostDidUpdateDirectory(_ directory: String?) {
        guard let raw = directory,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.isFileURL
        else { return }

        let host = url.host ?? ""
        let isLocal = host.isEmpty
            || host == "localhost"
            || host == ProcessInfo.processInfo.hostName
            || host == ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        guard isLocal else { return }

        processMonitor?.reportHostDirectory(url.path)
    }

    // MARK: - Alternate Screen Scoping

    /// Foreground process group seen on the last check. Used to avoid resolving
    /// the process name on every chunk — it only changes when the job does.
    private var lastForegroundPgid: pid_t = -1

    /// Enable the scrollback filter only while an AI CLI owns the terminal.
    ///
    /// The filter's purpose is to keep a CLI's conversation history in the main
    /// buffer instead of a throwaway alternate screen. Applied indiscriminately
    /// it breaks every other full-screen program, because it swallows both the
    /// buffer switch and the clear that follows — so the program paints on top
    /// of the previous screen's contents. Asking the PTY who is in the
    /// foreground keeps the feature for the case it was written for and gets it
    /// out of the way of everything else.
    private func updateAltScreenScope() {
        guard AppConfiguration.shared.disableAltScreen else {
            altScreenFilter.setEnabled(false)
            return
        }

        let pgid = ProcessTreeQuery.foregroundProcessGroup(ptyFd: process?.childfd ?? -1)
        guard pgid != lastForegroundPgid else { return }
        lastForegroundPgid = pgid

        // The process group leader is the job the user launched, so this reads
        // `claude`/`gemini` for a CLI and `ssh`/`vim`/`less` for anything else.
        let isCLI = pgid > 0 && ProcessTreeQuery.detectCLIProvider(pid: pgid) != nil
        altScreenFilter.setEnabled(isCLI)
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
        updateAltScreenScope()
        let filtered = altScreenFilter.filter(slice)
        guard !filtered.isEmpty else { return }

        let wasScrolledUp = canScroll && scrollPosition < 1.0
        let savedYDisp = getTerminal().buffer.yDisp

        // Prevent feedPrepare() from clearing text selection during output
        let savedMouseReporting = allowMouseReporting
        allowMouseReporting = false

        if wasScrolledUp { suppressScrollerUpdate = true }

        super.dataReceived(slice: filtered)

        allowMouseReporting = savedMouseReporting

        if wasScrolledUp {
            getTerminal().buffer.yDisp = savedYDisp
            suppressScrollerUpdate = false
            // Trigger scroller update with restored position
            super.scrolled(source: getTerminal(), yDisp: savedYDisp)
        }

        // Trigger debounced context usage scan after buffer is updated
        scheduleContextScan()
    }

    func configureAppearance() {
        let config = AppConfiguration.shared
        let theme = config.currentTheme
        // Custom font name falls back to monospaced system font if invalid.
        if let custom = NSFont(name: config.fontName, size: config.fontSize) {
            font = custom
        } else {
            font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        }
        nativeForegroundColor = theme.foreground
        // SwiftTerm carries the alpha through to the layer that paints the
        // background and margins, so translucency needs nothing more than a
        // colour with alpha — plus a non-opaque window, set in MainWindow.
        let opacity = min(max(config.backgroundOpacity, 0.3), 1.0)
        nativeBackgroundColor = opacity < 1.0
            ? theme.background.withAlphaComponent(opacity)
            : theme.background

        // The caret kept SwiftTerm's default colour and shape, so it ignored the
        // selected theme entirely. `cursorStyleChanged` is the public path that
        // also refreshes the caret view; setting `options` alone would not.
        caretColor = theme.resolvedCursor
        let style = CursorStyle.allCases.first { $0.tagName == config.cursorStyle }
            ?? .steadyBlock
        getTerminal().options.cursorStyle = style
        cursorStyleChanged(source: getTerminal(), newStyle: style)

        changeScrollback(5000)
        getTerminal().options.kittyImageCacheLimitBytes = 1_000_000
        getTerminal().options.enableSixelReported = false
        // Force the next scope check to re-resolve, so toggling the setting
        // takes effect without waiting for the foreground job to change.
        lastForegroundPgid = -1
        updateAltScreenScope()

        // Install themed ANSI palette so CLI tools' colored UI blocks blend in.
        installColors(theme.ansiPalette)
    }

    @objc private func handleConfigurationChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.configureAppearance()
            self?.needsDisplay = true
        }
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
        case "v": // Cmd+V — if clipboard has image but no text, send Ctrl+V so CLI handles paste
            let pb = NSPasteboard.general
            let hasText = pb.string(forType: .string) != nil
            let hasImage = pb.types?.contains(where: { [.png, .tiff, .fileURL].contains($0) }) ?? false
            if !hasText && hasImage {
                send(txt: "\u{16}") // Ctrl+V — CLI reads clipboard itself
                return true
            }
            return super.performKeyEquivalent(with: event)
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
        case "=": // Alias for Cmd++ so the shortcut works without pressing Shift.
            AppCommands.adjustFontSize(by: 1)
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
