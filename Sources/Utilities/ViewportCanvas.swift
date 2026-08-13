import Foundation
import SwiftTerm

/// Produces the blank screen that a suppressed alternate-buffer switch promised.
///
/// `AltScreenFilter` swallows the switch so an AI CLI paints into the main
/// buffer and its conversation stays scrollable. The switch it swallowed was
/// also the CLI's guarantee of an empty canvas, and nothing else in the stream
/// provides one, so the host has to hand it over here.
enum ViewportCanvas {

    /// Scroll everything above the cursor out of the viewport and into scrollback.
    ///
    /// Erasing is the obvious way to blank a screen and the wrong one:
    /// `Terminal.cmdEraseInDisplay` overwrites the visible rows where they sit,
    /// which would delete the shell output the user still wants to scroll back
    /// to — the very thing the filter swallowed the switch to protect.
    /// Scrolling arrives at the same empty viewport with that output pushed
    /// into history instead.
    ///
    /// Rows below the cursor are left alone: the CLI's own erase follows this
    /// call and clears them, and scrolling far enough to cover them would push
    /// a screenful of blank lines into the history.
    static func clearPreservingScrollback(_ terminal: Terminal) {
        let buffer = terminal.buffer
        let rowsToScroll = min(buffer.y, terminal.rows)
        guard rowsToScroll > 0 else { return }

        for _ in 0..<rowsToScroll {
            terminal.scroll()
        }

        // `scroll` moves the contents and not the caret, so without this the
        // cursor would sit `rowsToScroll` rows below the line it was on.
        buffer.y = max(buffer.y - rowsToScroll, 0)
        terminal.updateFullScreen()
    }
}
