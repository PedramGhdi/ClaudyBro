import Foundation

/// Filters terminal escape sequences from a PTY byte stream to preserve scrollback.
///
/// When enabled, strips:
/// - CSI sequences that set/reset DEC private modes 47, 1047, 1049 (alternate screen buffer)
/// - CSI 3J (erase scrollback buffer) — prevents scrollback destruction
/// - CSI 2J (erase entire display) — only while in virtual alt-screen, to prevent the TUI
///   from wiping conversation history on the main buffer
///
/// Swallowing the switch also swallows the blank screen it guaranteed, so the
/// enter is reported to the host as `.clearViewport` rather than simply
/// dropped. Without it the CLI paints straight over whatever the shell had on
/// screen and the two interleave, cell by cell.
///
/// When combined parameters are present (e.g., `ESC[?1049;25h`), only the alt-screen
/// parameters are removed; remaining parameters are preserved.
///
/// Handles sequences that may be split across consecutive data chunks via a small residual buffer.
///
/// - Important: This is only ever appropriate for an AI CLI's own output. Any
///   other full-screen program — `vim`, `less`, `man`, `htop`, `tmux`, and
///   anything reached over `ssh` — genuinely needs the alternate buffer, and
///   filtering it makes them paint over whatever was already on screen. The
///   owner is responsible for enabling this only while such a CLI is the
///   terminal's foreground job; see `ClaudyTerminalView.updateAltScreenScope`.
final class AltScreenFilter {

    /// A piece of filtered stream: bytes to feed the emulator, or an action the
    /// host has to perform against the live terminal at this exact point in it.
    enum Output {
        case data(ArraySlice<UInt8>)

        /// An alternate-screen enter was swallowed here. The host owes the CLI
        /// the empty screen the real switch would have given it, without
        /// discarding what is currently displayed.
        case clearViewport
    }

    private(set) var isEnabled: Bool = true

    /// Whether we've blocked an alt-screen enter, meaning the TUI thinks it's in
    /// the alternate buffer but is actually writing to the main buffer.
    private(set) var inVirtualAltScreen: Bool = false

    /// Turn filtering on or off, clearing the virtual alt-screen latch.
    ///
    /// The latch records that we swallowed an alt-screen *enter*, and it is
    /// normally cleared by the matching exit. When a program dies without
    /// sending one — a dropped SSH session, `kill -9`, a crash — the latch
    /// would otherwise stay set for the life of the tab and keep swallowing
    /// every subsequent `CSI 2J`, which is how plain `clear` stops working.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        reset()
    }

    /// Clear the virtual alt-screen latch. Called on enable/disable and when a
    /// CLI exits.
    ///
    /// Deliberately leaves `residual` alone: those bytes are the front of an
    /// escape sequence split across chunks, and dropping them would emit the
    /// tail as literal garbage. The disabled path in `filter` flushes them
    /// verbatim on the next chunk, which is the correct handoff.
    func reset() {
        inVirtualAltScreen = false
        entryEraseArmed = false
    }

    /// Whether the next `CSI 2J` is the CLI's fresh-canvas clear, paired with an
    /// alt-screen enter we just swallowed, and so may be passed through.
    ///
    /// Every later one is stripped, because by then the screen holds the
    /// conversation itself. A CLI redraws its live frame after a resize but not
    /// the transcript above it, so honouring that erase would blank output no
    /// one is going to paint again.
    ///
    /// Disarmed by the first printable byte: a clear that arrives before the
    /// CLI has drawn anything is the entry clear, one that arrives after it is
    /// not.
    private var entryEraseArmed: Bool = false

    /// Bytes held from the previous chunk that may be the start of an escape sequence.
    private var residual: [UInt8] = []

    /// The DEC private mode numbers to strip.
    private static let altScreenModes: Set<Int> = [47, 1047, 1049]

    /// Maximum bytes after ESC needed to fully identify a target sequence.
    private static let maxSequenceLength = 32

    // MARK: - Public API

    /// Filter a data chunk into segments: bytes to feed, and any host actions
    /// that have to happen between them.
    func filter(_ slice: ArraySlice<UInt8>) -> [Output] {
        guard isEnabled else {
            if !residual.isEmpty {
                let flushed = residual + Array(slice)
                residual.removeAll()
                return [.data(flushed[...])]
            }
            return slice.isEmpty ? [] : [.data(slice)]
        }

        var buf: [UInt8]
        if residual.isEmpty {
            buf = Array(slice)
        } else {
            buf = residual + Array(slice)
            residual.removeAll()
        }

        guard !buf.isEmpty else { return [] }

        var segments = [Output]()
        var output = [UInt8]()
        output.reserveCapacity(buf.count)
        var i = 0

        // Hand off everything accumulated so far, so that an action lands
        // between the bytes that precede it and the ones that follow.
        func flush() {
            guard !output.isEmpty else { return }
            segments.append(.data(output[...]))
            output = []
        }

        while i < buf.count {
            if buf[i] == 0x1B { // ESC
                // RIS (ESC c) — a full terminal reset. Whatever alt-screen
                // state we were tracking is void; forward it untouched.
                if i + 1 < buf.count && buf[i + 1] == 0x63 {
                    inVirtualAltScreen = false
                    entryEraseArmed = false
                    output.append(buf[i])
                    output.append(buf[i + 1])
                    i += 2
                    continue
                }

                let result = tryParseCSI(buf, from: i)
                switch result {
                case .notCSI:
                    output.append(buf[i])
                    i += 1

                case .incomplete:
                    residual = Array(buf[i...])
                    flush()
                    return segments

                case .keep(let length):
                    output.append(contentsOf: buf[i..<(i + length)])
                    i += length

                case .strip(let length):
                    i += length

                case .rewrite(let replacement, let length):
                    output.append(contentsOf: replacement)
                    i += length

                case .clearViewport(let replacement, let length):
                    output.append(contentsOf: replacement)
                    flush()
                    segments.append(.clearViewport)
                    i += length
                }
            } else {
                // The CLI is painting, so any clear from here on is a redraw of
                // its own output rather than the one that pairs with the switch.
                if buf[i] >= 0x20 { entryEraseArmed = false }
                output.append(buf[i])
                i += 1
            }
        }

        flush()
        return segments
    }

    // MARK: - CSI Parsing

    private enum ParseResult {
        case notCSI
        case incomplete
        case keep(Int)
        case strip(Int)
        case rewrite([UInt8], Int)

        /// Drop the sequence, emit `[UInt8]` in its place (empty when nothing
        /// survives the edit), and tell the host to blank the viewport.
        case clearViewport([UInt8], Int)
    }

    /// Attempt to parse a CSI sequence starting at `buf[from]` (which is ESC).
    private func tryParseCSI(_ buf: [UInt8], from start: Int) -> ParseResult {
        let remaining = buf.count - start

        // Need at least ESC [
        if remaining < 2 { return .incomplete }
        guard buf[start + 1] == 0x5B else { return .notCSI } // [

        if remaining < 3 { return .incomplete }

        if buf[start + 2] == 0x3F { // ?
            // DEC private mode sequence: CSI ? ...
            return parseDECPrivate(buf, from: start)
        }

        // Standard CSI sequence: CSI params final
        return parseStandardCSI(buf, from: start)
    }

    // MARK: - DEC Private Mode Parsing (Alt-Screen)

    /// Parse a DEC private mode sequence: ESC [ ? params h/l
    private func parseDECPrivate(_ buf: [UInt8], from start: Int) -> ParseResult {
        // Parse parameter bytes (0x30-0x3F) until we hit the final byte (0x40-0x7E)
        var pos = start + 3
        while pos < buf.count {
            let b = buf[pos]
            if b >= 0x30 && b <= 0x3F {
                // Parameter byte (digits 0-9, semicolons, etc.)
                pos += 1
                if pos - start > Self.maxSequenceLength { return .notCSI }
                continue
            }
            if b >= 0x40 && b <= 0x7E {
                // Final byte — sequence is complete
                let finalByte = b
                let seqLength = pos - start + 1

                // Only care about 'h' (set) and 'l' (reset)
                guard finalByte == 0x68 || finalByte == 0x6C else {
                    return .keep(seqLength)
                }

                let paramBytes = buf[(start + 3)..<pos]
                return classifyDECParams(Array(paramBytes), finalByte: finalByte, seqLength: seqLength)
            }
            if b >= 0x20 && b <= 0x2F {
                // Intermediate byte — not our target pattern
                return .keep(findSequenceEnd(buf, from: pos) - start)
            }
            // Invalid byte in sequence
            return .notCSI
        }

        // Ran out of bytes — sequence is incomplete
        return .incomplete
    }

    /// Classify a parsed DEC private mode sequence by its parameters.
    private func classifyDECParams(_ paramBytes: [UInt8], finalByte: UInt8, seqLength: Int) -> ParseResult {
        let paramString = String(bytes: paramBytes, encoding: .ascii) ?? ""
        let params = paramString.split(separator: ";").compactMap { Int($0) }

        guard !params.isEmpty else { return .keep(seqLength) }

        let altParams = params.filter { Self.altScreenModes.contains($0) }
        let otherParams = params.filter { !Self.altScreenModes.contains($0) }

        if altParams.isEmpty {
            return .keep(seqLength)
        }

        // Update virtual alt-screen state
        let entering = (finalByte == 0x68) // 'h' = set mode (enter), 'l' = reset (exit)

        // Entering owes the CLI a blank screen. Re-entering does not: it is
        // already painting on one, and scrolling again would push a copy of its
        // own frame into the history.
        let owesBlankScreen = entering && !inVirtualAltScreen
        if owesBlankScreen { entryEraseArmed = true }
        if !entering { entryEraseArmed = false }
        inVirtualAltScreen = entering

        // Mixed parameters keep the ones that are not ours (`ESC[?1049;25h`
        // still has to show the cursor); an all-alt-screen sequence leaves
        // nothing behind.
        let replacement: [UInt8]
        if otherParams.isEmpty {
            replacement = []
        } else {
            let newParamString = otherParams.map(String.init).joined(separator: ";")
            replacement = [0x1B, 0x5B, 0x3F] + Array(newParamString.utf8) + [finalByte]
        }

        if owesBlankScreen {
            return .clearViewport(replacement, seqLength)
        }
        return replacement.isEmpty ? .strip(seqLength) : .rewrite(replacement, seqLength)
    }

    // MARK: - Standard CSI Parsing (Erase in Display)

    /// Parse a standard CSI sequence: ESC [ params final
    private func parseStandardCSI(_ buf: [UInt8], from start: Int) -> ParseResult {
        var pos = start + 2
        while pos < buf.count {
            let b = buf[pos]
            if b >= 0x30 && b <= 0x3F {
                // Parameter byte
                pos += 1
                if pos - start > Self.maxSequenceLength { return .notCSI }
                continue
            }
            if b >= 0x40 && b <= 0x7E {
                // Final byte — sequence is complete
                let finalByte = b
                let seqLength = pos - start + 1
                return classifyStandardCSI(buf, paramStart: start + 2, paramEnd: pos, finalByte: finalByte, seqLength: seqLength)
            }
            if b >= 0x20 && b <= 0x2F {
                // Intermediate byte — not a sequence we rewrite, but DECSTR
                // (ESC [ ! p) is a soft reset and must clear the latch for the
                // same reason RIS does.
                let end = findSequenceEnd(buf, from: pos)
                if b == 0x21, end <= buf.count, buf[end - 1] == 0x70 { // '!' … 'p'
                    inVirtualAltScreen = false
                }
                return .keep(end - start)
            }
            return .notCSI
        }
        return .incomplete
    }

    /// Classify a standard CSI sequence — filter destructive erase operations.
    private func classifyStandardCSI(_ buf: [UInt8], paramStart: Int, paramEnd: Int, finalByte: UInt8, seqLength: Int) -> ParseResult {
        // Only interested in ED (Erase in Display): final byte 'J' = 0x4A
        guard finalByte == 0x4A else { return .keep(seqLength) }

        let paramBytes = buf[paramStart..<paramEnd]
        let paramString = String(bytes: paramBytes, encoding: .ascii) ?? ""
        let param = Int(paramString) ?? 0

        switch param {
        case 3:
            // CSI 3J — Erase scrollback buffer. Always strip to protect history.
            return .strip(seqLength)
        case 2 where inVirtualAltScreen && entryEraseArmed:
            // The clear that pairs with the switch we just swallowed. The
            // viewport was scrolled into scrollback for it, so erasing now
            // costs nothing and clears any row the scroll left behind.
            entryEraseArmed = false
            return .keep(seqLength)
        case 2 where inVirtualAltScreen:
            // CSI 2J — Erase entire display. Strip while TUI is managing main buffer,
            // so it can't wipe out conversation history visible on the main screen.
            return .strip(seqLength)
        default:
            return .keep(seqLength)
        }
    }

    // MARK: - Helpers

    /// Find the end of a CSI sequence (for sequences we want to keep as-is).
    private func findSequenceEnd(_ buf: [UInt8], from start: Int) -> Int {
        var pos = start
        while pos < buf.count {
            if buf[pos] >= 0x40 && buf[pos] <= 0x7E { return pos + 1 }
            pos += 1
        }
        return buf.count
    }
}
