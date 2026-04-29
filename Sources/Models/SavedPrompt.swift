import Foundation

/// User-defined snippet that can be fired into the active terminal from the
/// command palette or settings.
struct SavedPrompt: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var body: String

    init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}
