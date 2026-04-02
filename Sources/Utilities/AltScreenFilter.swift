import Foundation

/// Filters terminal escape sequences from a PTY byte stream to preserve scrollback.
///
/// When enabled, strips:
/// - CSI sequences that set/reset DEC private modes 47, 1047, 1049 (alternate screen buffer)
/// - CSI 3J (erase scrollback buffer) — prevents scrollback destruction
/// - CSI 2J (erase entire display) — only while in virtual alt-screen, to prevent the TUI
///   from wiping conversation history on the main buffer
///
/// When combined parameters are present (e.g., `ESC[?1049;25h`), only the alt-screen
/// parameters are removed; remaining parameters are preserved.
///
/// Handles sequences that may be split across consecutive data chunks via a small residual buffer.
final class AltScreenFilter {

    var isEnabled: Bool = true

    /// Whether we've blocked an alt-screen enter, meaning the TUI thinks it's in
    /// the alternate buffer but is actually writing to the main buffer.
    private(set) var inVirtualAltScreen: Bool = false

    /// Bytes held from the previous chunk that may be the start of an escape sequence.
    private var residual: [UInt8] = []

    /// The DEC private mode numbers to strip.
    private static let altScreenModes: Set<Int> = [47, 1047, 1049]

    /// Maximum bytes after ESC needed to fully identify a target sequence.
    private static let maxSequenceLength = 32

    // MARK: - Public API

    /// Filter a data chunk, returning bytes with filtered sequences removed.
    func filter(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard isEnabled else {
            if !residual.isEmpty {
                let flushed = residual + Array(slice)
                residual.removeAll()
                return flushed[...]
            }
            return slice
        }

        var buf: [UInt8]
        if residual.isEmpty {
            buf = Array(slice)
        } else {
            buf = residual + Array(slice)
            residual.removeAll()
        }

        guard !buf.isEmpty else { return [][...] }

        var output = [UInt8]()
        output.reserveCapacity(buf.count)
        var i = 0

        while i < buf.count {
            if buf[i] == 0x1B { // ESC
                let result = tryParseCSI(buf, from: i)
                switch result {
                case .notCSI:
                    output.append(buf[i])
                    i += 1

                case .incomplete:
                    residual = Array(buf[i...])
                    return output[...]

                case .keep(let length):
                    output.append(contentsOf: buf[i..<(i + length)])
                    i += length

                case .strip(let length):
                    i += length

                case .rewrite(let replacement, let length):
                    output.append(contentsOf: replacement)
                    i += length
                }
            } else {
                output.append(buf[i])
                i += 1
            }
        }

        return output[...]
    }

    // MARK: - CSI Parsing

    private enum ParseResult {
        case notCSI
        case incomplete
        case keep(Int)
        case strip(Int)
        case rewrite([UInt8], Int)
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

        if otherParams.isEmpty {
            // All params are alt-screen — strip the entire sequence
            inVirtualAltScreen = entering
            return .strip(seqLength)
        }

        // Mixed: rewrite with only the non-alt-screen params
        inVirtualAltScreen = entering
        let newParamString = otherParams.map(String.init).joined(separator: ";")
        let rewritten: [UInt8] = [0x1B, 0x5B, 0x3F] +
            Array(newParamString.utf8) +
            [finalByte]
        return .rewrite(rewritten, seqLength)
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
                // Intermediate byte — not our target
                return .keep(findSequenceEnd(buf, from: pos) - start)
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
