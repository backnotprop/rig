import XCTest
@testable import Rig

final class RigTests: XCTestCase {
    func testSessionStoreRoundTripsPersistedState() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("sessions.json")
        let store = SessionStore(fileURL: fileURL)
        let session = makeSession(label: "Session 1")
        let state = PersistedSessions(nextSessionOrdinal: 2, sessions: [session])

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
    }

    func testSessionStoreReturnsEmptyStateWhenFileIsMissing() throws {
        let store = SessionStore(
            fileURL: temporaryDirectory().appendingPathComponent("missing.json")
        )

        XCTAssertEqual(try store.load(), .empty)
    }

    @MainActor
    func testCreateSessionUsesSequentialAutoNamesAndHomeDirectory() async throws {
        let controller = FakeGhosttyController()
        let store = SessionStore(fileURL: temporaryDirectory().appendingPathComponent("sessions.json"))
        let viewModel = SessionListViewModel(
            controller: controller,
            store: store,
            homeDirectory: "/Users/tester"
        )

        await viewModel.start()
        await viewModel.createSession()
        await viewModel.createSession()

        let createdWorkingDirectories = await controller.createdWorkingDirectoriesSnapshot()

        XCTAssertEqual(viewModel.sessions.map(\.label), ["Session 1", "Session 2"])
        XCTAssertEqual(createdWorkingDirectories, ["/Users/tester", "/Users/tester"])
    }

    @MainActor
    func testFocusReportsErrorWhenControllerFails() async throws {
        let controller = FakeGhosttyController()
        let store = SessionStore(fileURL: temporaryDirectory().appendingPathComponent("sessions.json"))
        let viewModel = SessionListViewModel(
            controller: controller,
            store: store,
            homeDirectory: "/Users/tester"
        )

        await viewModel.start()
        await viewModel.createSession()
        let session = try XCTUnwrap(viewModel.sessions.first)
        await controller.setShouldFailFocus(true)

        await viewModel.focus(session)

        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.sessions.count, 1)
    }

    @MainActor
    func testRemoveSelectedDoesNothingWithoutExplicitSelection() async throws {
        let controller = FakeGhosttyController()
        let store = SessionStore(fileURL: temporaryDirectory().appendingPathComponent("sessions.json"))
        let session = makeSession(label: "Session 1")
        try store.save(PersistedSessions(nextSessionOrdinal: 2, sessions: [session]))

        let viewModel = SessionListViewModel(controller: controller, store: store)
        await viewModel.start()
        viewModel.removeSelected()

        XCTAssertEqual(viewModel.sessions.map(\.id), [session.id])
    }

    func testGhosttyIntegrationCreateAndFocus() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GHOSTTY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_GHOSTTY_INTEGRATION=1 to create and focus a real Ghostty window.")
        }

        let controller = await AppleScriptGhosttyController()
        let created = try await controller.createWindow(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )

        _ = try await controller.focusTerminal(
            windowId: created.windowId,
            tabId: created.tabId,
            terminalId: created.terminalId
        )
    }

    private func makeSession(label: String) -> GhosttySession {
        GhosttySession(
            id: UUID(),
            label: label,
            ghosttyWindowId: "window-1",
            ghosttyTabId: "tab-1",
            ghosttyTerminalId: "terminal-1"
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor FakeGhosttyController: GhosttyControlling {
    private var counter = 0
    private var createdWorkingDirectories: [String] = []
    private var shouldFailFocus = false

    func setShouldFailFocus(_ value: Bool) {
        shouldFailFocus = value
    }

    func createdWorkingDirectoriesSnapshot() -> [String] {
        createdWorkingDirectories
    }

    func createWindow(workingDirectory: String) async throws -> CreatedGhosttySurface {
        try Task.checkCancellation()

        counter += 1
        createdWorkingDirectories.append(workingDirectory)

        return CreatedGhosttySurface(
            windowId: "window-\(counter)",
            tabId: "tab-\(counter)",
            terminalId: "terminal-\(counter)",
            workingDirectory: workingDirectory
        )
    }

    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface {
        try Task.checkCancellation()

        if shouldFailFocus {
            throw GhosttyControllerError.scriptExecutionFailed("Missing terminal")
        }

        return CreatedGhosttySurface(
            windowId: windowId,
            tabId: tabId,
            terminalId: terminalId,
            workingDirectory: "/Users/tester"
        )
    }
}
