import AppKit
import SwiftTerm

/// On-disk representation of a theme, loaded from `~/.config/claudybro/themes`.
///
/// Kept separate from `Theme` so the in-memory type stays free of persistence
/// concerns and can go on using `NSColor` directly. Colors are hex strings —
/// what every other terminal's theme format uses, and what anyone hand-writing
/// one will expect.
struct ThemeFile: Codable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    let statusBarBackground: String?
    let cursor: String?
    /// Exactly 16 entries: ANSI 0-7 then their bright counterparts.
    let ansi: [String]

    enum LoadError: LocalizedError {
        case badColor(String)
        case wrongPaletteSize(Int)

        var errorDescription: String? {
            switch self {
            case .badColor(let value):
                return "'\(value)' is not a hex color like #1a1a2e"
            case .wrongPaletteSize(let count):
                return "'ansi' needs exactly 16 colors, found \(count)"
            }
        }
    }

    func toTheme() throws -> Theme {
        guard ansi.count == 16 else { throw LoadError.wrongPaletteSize(ansi.count) }
        let palette = try ansi.map { try Self.terminalColor($0) }
        return Theme(
            id: id,
            name: name,
            background: try Self.color(background),
            foreground: try Self.color(foreground),
            statusBarBackground: try statusBarBackground.map(Self.color)
                ?? Self.color(background),
            ansiPalette: palette,
            cursor: try cursor.map(Self.color)
        )
    }

    // MARK: - Hex parsing

    /// Accepts `#rgb`, `#rrggbb`, and the same without the leading `#`.
    private static func components(_ hex: String) throws -> (UInt16, UInt16, UInt16) {
        var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }

        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            throw LoadError.badColor(hex)
        }
        return (
            UInt16((value >> 16) & 0xFF),
            UInt16((value >> 8) & 0xFF),
            UInt16(value & 0xFF)
        )
    }

    private static func color(_ hex: String) throws -> NSColor {
        let (r, g, b) = try components(hex)
        return NSColor(
            red: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1
        )
    }

    private static func terminalColor(_ hex: String) throws -> SwiftTerm.Color {
        let (r, g, b) = try components(hex)
        // SwiftTerm stores 16-bit channels; 257 maps 0xFF to 0xFFFF exactly.
        return SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}

// MARK: - Loading

extension Theme {
    static var userThemesDirectory: URL {
        Constants.configDirectory.appendingPathComponent("themes")
    }

    /// Themes found in the user's themes directory.
    ///
    /// A malformed file is skipped rather than taken as fatal — one bad theme
    /// should never stop the app from starting — but the reason is logged so it
    /// is discoverable rather than silently ignored.
    static func loadUserThemes() -> [Theme] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: userThemesDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(ThemeFile.self, from: data).toTheme()
                } catch {
                    NSLog(
                        "ClaudyBro: skipping theme %@ — %@",
                        url.lastPathComponent, error.localizedDescription
                    )
                    return nil
                }
            }
    }
}
