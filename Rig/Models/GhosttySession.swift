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
    /// Whether the corresponding Ghostty window is currently hidden
    /// (orderOut'd via AppleScript). Flipped true on background launch,
    /// false when the user clicks the session to bring it back.
    var isBackgrounded: Bool = false
    /// The macOS-level window ID (kCGWindowNumber) captured at creation time.
    /// Used by SpaceSwitcher to find which Space the window lives on. Zero
    /// means we couldn't capture it (Ghostty not running, timing race, etc.).
    var cgWindowID: CGWindowID = 0
}
