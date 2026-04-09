import Foundation

/// Suppresses OSC color query responses (OSC 4, 10, 11, 12) that SwiftTerm
/// sends back through the PTY. These specific responses leak into the shell
/// as plaintext, producing errors like `zsh: command not found: 11`.
///
/// Only color-related OSC responses are filtered. All other terminal responses
/// (DA, cursor position, DCS, clipboard, title reports) pass through — CLI
/// tools need them for proper terminal capability detection and initialization.
struct OSCResponseFilter {

    var isEnabled: Bool = true

    /// Returns true if the data is an OSC color query response that should be suppressed.
    func shouldSuppress(_ data: ArraySlice<UInt8>) -> Bool {
        guard isEnabled, data.count >= 4 else { return false }

        // Identify OSC introducer and find payload start
        let payloadStart: Int
        if data[data.startIndex] == 0x9d {
            payloadStart = data.startIndex + 1
        } else if data[data.startIndex] == 0x1b, data[data.startIndex + 1] == 0x5d {
            payloadStart = data.startIndex + 2
        } else {
            return false
        }

        // Parse numeric OSC code before first ';'
        var pos = payloadStart
        while pos < data.endIndex, data[pos] >= 0x30, data[pos] <= 0x39 { pos += 1 }
        guard pos > payloadStart, pos < data.endIndex, data[pos] == 0x3b else { return false }

        // Fast path: check first digit — codes 4, 10, 11, 12 all start with '1' or '4'
        let firstDigit = data[payloadStart]
        guard firstDigit == 0x31 || firstDigit == 0x34 else { return false }

        let digitCount = pos - payloadStart
        if digitCount == 1 {
            // Single digit: only suppress "4" (color index query)
            return firstDigit == 0x34
        }
        if digitCount == 2 {
            // Two digits: suppress 10, 11, 12
            let secondDigit = data[payloadStart + 1]
            return firstDigit == 0x31 && (secondDigit >= 0x30 && secondDigit <= 0x32)
        }
        return false
    }
}
