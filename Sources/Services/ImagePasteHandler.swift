import AppKit
import Foundation

/// Handles image-aware paste: detects image data in the system clipboard,
/// saves it to a temp file, and returns the file path for terminal injection.
///
/// Optimized to skip the slow NSImage → TIFF → BitmapRep → PNG pipeline.
/// Instead grabs raw pasteboard data and writes it directly to disk.
final class ImagePasteHandler {
    private var tempDirReady = false

    init() {
        ensureTempDirectory()
    }

    /// Check the system pasteboard for image data.
    /// Returns the saved file path if an image was found, nil otherwise.
    func extractImageFromPasteboard() -> String? {
        let pasteboard = NSPasteboard.general

        // Fast path 1: File URL(s) pointing to image files — zero copy, instant
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let imageURLs = urls.filter {
                Constants.imageExtensions.contains($0.pathExtension.lowercased())
            }
            if !imageURLs.isEmpty {
                return imageURLs.map(\.path).joined(separator: " ")
            }
        }

        // Fast path 2: Raw PNG bytes on pasteboard (screenshots, copied images)
        // Skips NSImage creation + TIFF conversion + BitmapRep + PNG re-encoding
        if let pngData = pasteboard.data(forType: .png) {
            return writeToTemp(data: pngData, ext: "png")
        }

        // Fast path 3: Raw TIFF data (some apps put TIFF on the pasteboard)
        if let tiffData = pasteboard.data(forType: .tiff) {
            return writeToTemp(data: tiffData, ext: "tiff")
        }

        // Slow fallback: NSImage conversion (rare — only when neither PNG nor TIFF is available)
        if let image = NSImage(pasteboard: pasteboard) {
            return saveImageSlow(image)
        }

        return nil
    }

    // MARK: - Private

    /// Direct raw data write — no encoding, no conversion.
    private func writeToTemp(data: Data, ext: String) -> String? {
        if !tempDirReady { ensureTempDirectory() }
        let path = "\(Constants.tempDirectory)/paste-\(timestamp()).\(ext)"
        // Non-atomic write (faster — no temp file + rename dance, unique filename is safe)
        return FileManager.default.createFile(atPath: path, contents: data) ? path : nil
    }

    /// Fallback for when only NSImage is available (rare).
    private func saveImageSlow(_ image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return writeToTemp(data: pngData, ext: "png")
    }

    private func timestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func ensureTempDirectory() {
        try? FileManager.default.createDirectory(
            atPath: Constants.tempDirectory,
            withIntermediateDirectories: true
        )
        tempDirReady = true
    }
}
