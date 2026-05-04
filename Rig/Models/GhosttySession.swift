import Foundation

/// In-memory only. Sessions are not persisted across app launches because the
/// Ghostty surface IDs they reference go stale the moment Ghostty quits.
struct GhosttySession: Identifiable, Equatable {
    let id: UUID
    var label: String
    var harnessID: String?
    var projectID: UUID?
    var ghosttyWindowId: String
    var ghosttyTabId: String
    var ghosttyTerminalId: String
}
