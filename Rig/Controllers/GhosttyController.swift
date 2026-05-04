import Foundation

protocol GhosttyControlling: Sendable {
    /// Creates a new Ghostty window. If `initialInput` is non-empty, it's typed into
    /// the new shell after launch (with a trailing newline) — used to run the harness's
    /// startup command.
    func createWindow(
        workingDirectory: String,
        initialInput: String?
    ) async throws -> CreatedGhosttySurface

    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface
}
