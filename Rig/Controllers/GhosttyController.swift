import Foundation

protocol GhosttyControlling: Sendable {
    /// Creates a new Ghostty window. If `initialInput` is non-empty, it's typed into
    /// the new shell after launch (with a trailing newline) — used to run the harness's
    /// startup command. When `bringToFront` is false, skip the post-creation `focus` /
    /// `activate` so the window appears in the background without stealing focus from
    /// the user's current app.
    func createWindow(
        workingDirectory: String,
        initialInput: String?,
        environmentVariables: [String],
        bringToFront: Bool
    ) async throws -> CreatedGhosttySurface

    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface

    func closeTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws

    func closeWindow(windowId: String) async throws
}
