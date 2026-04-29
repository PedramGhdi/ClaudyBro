import AppKit
import SwiftTerm

/// Color theme for the terminal + chrome.
struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let statusBarBackground: NSColor
    let ansiPalette: [SwiftTerm.Color]
}

extension Theme {
    static let allPresets: [Theme] = [
        .claudyBroDark, .warpDarkInspired, .solarizedDark, .dracula,
    ]

    static func preset(id: String) -> Theme {
        allPresets.first { $0.id == id } ?? .claudyBroDark
    }

    private static func ns(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private static func st(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    /// The original ClaudyBro dark navy theme.
    static let claudyBroDark = Theme(
        id: "claudybro-dark",
        name: "ClaudyBro Dark",
        background: ns(0.102, 0.102, 0.180),
        foreground: ns(0.878, 0.878, 0.878),
        statusBarBackground: ns(0.075, 0.075, 0.133),
        ansiPalette: [
            st( 26,  26,  46), st(255,  85,  85), st( 80, 250, 123), st(255, 204,   0),
            st( 89, 143, 255), st(209,  97, 255), st(  0, 205, 205), st(224, 224, 224),
            st( 75,  75, 100), st(255, 110, 110), st(105, 255, 148), st(255, 225,  80),
            st(120, 170, 255), st(225, 130, 255), st( 80, 230, 230), st(255, 255, 255),
        ]
    )

    /// Inspired by Warp's default dark palette (built from scratch — no Warp code copied).
    static let warpDarkInspired = Theme(
        id: "warp-dark-inspired",
        name: "Warp-Inspired Dark",
        background: ns(0.090, 0.094, 0.110),
        foreground: ns(0.878, 0.890, 0.910),
        statusBarBackground: ns(0.063, 0.067, 0.082),
        ansiPalette: [
            st( 23,  24,  28), st(255,  98, 109), st(135, 211, 124), st(255, 200,  87),
            st( 97, 175, 239), st(198, 120, 221), st( 86, 182, 194), st(220, 223, 228),
            st( 82,  85,  93), st(255, 134, 141), st(166, 226, 162), st(255, 218, 121),
            st(140, 195, 255), st(220, 158, 237), st(122, 211, 220), st(255, 255, 255),
        ]
    )

    static let solarizedDark = Theme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: ns(0.000, 0.169, 0.212),
        foreground: ns(0.514, 0.580, 0.588),
        statusBarBackground: ns(0.027, 0.212, 0.259),
        ansiPalette: [
            st(  7,  54,  66), st(220,  50,  47), st(133, 153,   0), st(181, 137,   0),
            st( 38, 139, 210), st(211,  54, 130), st( 42, 161, 152), st(238, 232, 213),
            st(  0,  43,  54), st(203,  75,  22), st( 88, 110, 117), st(101, 123, 131),
            st(131, 148, 150), st(108, 113, 196), st(147, 161, 161), st(253, 246, 227),
        ]
    )

    static let dracula = Theme(
        id: "dracula",
        name: "Dracula",
        background: ns(0.157, 0.165, 0.212),
        foreground: ns(0.973, 0.973, 0.949),
        statusBarBackground: ns(0.122, 0.129, 0.169),
        ansiPalette: [
            st( 33,  34,  44), st(255,  85,  85), st( 80, 250, 123), st(241, 250, 140),
            st(189, 147, 249), st(255, 121, 198), st(139, 233, 253), st(248, 248, 242),
            st( 98, 114, 164), st(255, 110, 110), st(105, 255, 148), st(255, 255, 165),
            st(214, 172, 255), st(255, 146, 223), st(164, 255, 255), st(255, 255, 255),
        ]
    )
}
