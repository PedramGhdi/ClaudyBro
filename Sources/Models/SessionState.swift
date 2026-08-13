import Foundation

/// Serializable snapshot of the window's tabs and split layout.
///
/// Only the *shape* of a session is restored — how many tabs, how they were
/// split, and where each terminal was working. Running processes are not, and
/// deliberately so: silently re-launching whatever was running would be a
/// surprising thing for a terminal to do on startup.
struct SessionState: Codable {
    var tabs: [TabState]
    var activeTabIndex: Int

    struct TabState: Codable {
        var layout: PaneLayout
        /// Index of the focused pane in `layout`'s left-to-right leaf order.
        var activeLeafIndex: Int
    }

    /// Mirror of `PaneNode` that can be written to disk. `PaneNode` itself owns
    /// live processes and view state, which have no business being encoded.
    indirect enum PaneLayout: Codable {
        case leaf(directory: String?)
        case split(vertical: Bool, children: [PaneLayout])

        var leafCount: Int {
            switch self {
            case .leaf: return 1
            case .split(_, let children): return children.reduce(0) { $0 + $1.leafCount }
            }
        }
    }

    // MARK: - Persistence

    static var fileURL: URL {
        Constants.configDirectory.appendingPathComponent("session.json")
    }

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
