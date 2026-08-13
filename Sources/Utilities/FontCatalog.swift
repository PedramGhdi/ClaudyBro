import AppKit

/// The installed fonts a terminal can reasonably use.
///
/// Discovery walks every font family on the system, so the list is built once
/// and reused: the settings sheet is opened often, the set of installed fonts
/// does not change while the app runs.
enum FontCatalog {
    /// The system monospaced face, and the app's default. macOS keeps its
    /// system fonts out of `availableFontFamilies`, and `NSFont(name:)` cannot
    /// resolve it either, so it is named and resolved as a special case rather
    /// than silently landing on the fallback.
    static let systemMonospacedName = "SF Mono"

    /// Monospaced families, system font first, then alphabetical.
    ///
    /// Falls back to a small known-good list if the system query comes back
    /// empty, so the picker is never a blank menu.
    static let monospacedFamilies: [String] = {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            face(ofFamily: family, size: 12)?.isFixedPitch == true
        }
        return [systemMonospacedName] + (families.isEmpty ? fallbackFamilies : families.sorted())
    }()

    private static let fallbackFamilies = ["Menlo", "Monaco", "Courier New"]

    /// Resolve a configured font name to a usable font.
    ///
    /// The name may be a family ("JetBrains Mono") or a PostScript face name
    /// ("JetBrainsMono-Regular") — config files written by hand contain both.
    /// Returns nil when neither resolves, leaving the fallback to the caller.
    static func font(named name: String, size: CGFloat) -> NSFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == systemMonospacedName {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: trimmed, size: size) ?? face(ofFamily: trimmed, size: size)
    }

    /// A representative face of a family. Needed because `NSFont(name:size:)`
    /// fails for families whose faces are named differently from the family.
    private static func face(ofFamily family: String, size: CGFloat) -> NSFont? {
        NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size)
    }
}
