import Foundation

protocol GhosttyControlling: Sendable {
    func createWindow(workingDirectory: String) async throws -> CreatedGhosttySurface
    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface
}
