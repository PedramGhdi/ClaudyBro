import AppKit

/// Actions shared between the menu bar, the command palette, and key handlers.
///
/// Keeping them here means a shortcut and its palette entry can never drift
/// apart, and the responder-chain plumbing is written once.
enum AppCommands {

    // MARK: - Find

    /// Drive SwiftTerm's built-in find bar through the responder chain.
    ///
    /// SwiftTerm implements `performTextFinderAction(_:)` and reads which
    /// operation was requested from the sender's menu-item tag, so we hand it a
    /// tagged item rather than reaching into a specific view. That way find
    /// follows the focus — whichever tab or split pane is first responder is
    /// the one that gets searched.
    static func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(
            #selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item
        )
    }

    // MARK: - Font size

    static func adjustFontSize(by delta: CGFloat) {
        setFontSize(AppConfiguration.shared.fontSize + delta)
    }

    static func resetFontSize() {
        setFontSize(Constants.defaultFontSize)
    }

    /// Font size lives in the shared configuration, so a change applies to every
    /// tab and split at once and survives a relaunch — matching how the Settings
    /// stepper already behaves.
    private static func setFontSize(_ size: CGFloat) {
        let config = AppConfiguration.shared
        let clamped = min(max(size, Constants.minFontSize), Constants.maxFontSize)
        guard clamped != config.fontSize else { return }
        config.fontSize = clamped
        config.save()
        NotificationCenter.default.post(name: .configurationChanged, object: nil)
    }
}
