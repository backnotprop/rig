import XCTest
@testable import Rig

final class RigTests: XCTestCase {
    @MainActor
    func testConfigStoreSeedsFirstRunWhenFileMissing() throws {
        let url = temporaryDirectory().appendingPathComponent("config.json")
        let store = ConfigStore(storeURL: url)

        XCTAssertEqual(store.config.version, 1)
        XCTAssertEqual(store.config.harnesses.map(\.id), ["pi", "claude-code", "codex", "opencode"])
        XCTAssertTrue(store.config.projects.isEmpty)
    }

    @MainActor
    func testConfigStoreRoundTripsHarnessEdits() throws {
        let url = temporaryDirectory().appendingPathComponent("config.json")
        let first = ConfigStore(storeURL: url)
        first.config.harnesses[0].command = "pi --debug"
        first.config.harnesses[0].enabled = false
        // Trigger an immediate write rather than wait for the debounced save.
        first.flushPendingSave()

        let second = ConfigStore(storeURL: url)
        XCTAssertEqual(second.config.harnesses[0].command, "pi --debug")
        XCTAssertFalse(second.config.harnesses[0].enabled)
    }

    @MainActor
    func testConfigStoreAddProjectMakesItSelectedAndRecent() throws {
        let url = temporaryDirectory().appendingPathComponent("config.json")
        let store = ConfigStore(storeURL: url)

        store.addProject(path: "/tmp/foo")

        XCTAssertEqual(store.config.projects.count, 1)
        XCTAssertEqual(store.selectedProject?.path, "/tmp/foo")
        XCTAssertEqual(store.recentProjects.first?.path, "/tmp/foo")
    }

    @MainActor
    func testCreateSessionUsesSequentialAutoNamesAndHomeDirectory() async throws {
        let controller = FakeGhosttyController()
        let viewModel = SessionListViewModel(
            controller: controller,
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
    func testCreateSessionUsesProvidedWorkingDirectoryAndPrefix() async throws {
        let controller = FakeGhosttyController()
        let viewModel = SessionListViewModel(
            controller: controller,
            homeDirectory: "/Users/tester"
        )

        await viewModel.start()
        await viewModel.createSession(
            workingDirectory: "/tmp/proj",
            command: "claude",
            harnessID: "claude-code",
            projectID: nil,
            labelPrefix: "Claude Code"
        )

        let cwds = await controller.createdWorkingDirectoriesSnapshot()
        let lastInput = await controller.lastInitialInputSnapshot()
        XCTAssertEqual(cwds, ["/tmp/proj"])
        XCTAssertEqual(lastInput, "claude")
        XCTAssertEqual(viewModel.sessions.first?.label, "Claude Code 1")
        XCTAssertEqual(viewModel.sessions.first?.harnessID, "claude-code")
    }

    @MainActor
    func testFocusReportsErrorWhenControllerFails() async throws {
        let controller = FakeGhosttyController()
        let viewModel = SessionListViewModel(
            controller: controller,
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
        let viewModel = SessionListViewModel(controller: controller)
        await viewModel.start()

        viewModel.removeSelected()

        XCTAssertTrue(viewModel.sessions.isEmpty)
    }

    func testComposedCommandReturnsBareCommandWhenNoFlagsSet() {
        let pi = Harness.builtinDefaults.first { $0.id == "pi" }!
        XCTAssertEqual(HarnessSchemas.composedCommand(for: pi), "pi")
    }

    func testComposedCommandAppendsToggleCLIFlag() {
        var codex = Harness.builtinDefaults.first { $0.id == "codex" }!
        codex.flags["yolo"] = .bool(true)
        XCTAssertEqual(HarnessSchemas.composedCommand(for: codex), "codex --yolo")
    }

    func testComposedCommandSkipsToggleWhenFalse() {
        var codex = Harness.builtinDefaults.first { $0.id == "codex" }!
        codex.flags["yolo"] = .bool(false)
        XCTAssertEqual(HarnessSchemas.composedCommand(for: codex), "codex")
    }

    func testComposedCommandClaudeWithYoloAndPicker() {
        var claude = Harness.builtinDefaults.first { $0.id == "claude-code" }!
        claude.flags["dangerously-skip-permissions"] = .bool(true)
        claude.flags["permission-mode"] = .string("plan")
        XCTAssertEqual(
            HarnessSchemas.composedCommand(for: claude),
            "claude --dangerously-skip-permissions --permission-mode plan"
        )
    }

    func testComposedCommandOmitsPickerWhenDefault() {
        var claude = Harness.builtinDefaults.first { $0.id == "claude-code" }!
        claude.flags["permission-mode"] = .string("default")
        XCTAssertEqual(HarnessSchemas.composedCommand(for: claude), "claude")
    }

    func testComposedCommandPreservesUserExtraArgsBeforeFlags() {
        var claude = Harness.builtinDefaults.first { $0.id == "claude-code" }!
        claude.command = "claude --verbose"
        claude.flags["dangerously-skip-permissions"] = .bool(true)
        XCTAssertEqual(
            HarnessSchemas.composedCommand(for: claude),
            "claude --verbose --dangerously-skip-permissions"
        )
    }

    func testComposedCommandWithEmptyCommandStillEmitsFlags() {
        var claude = Harness.builtinDefaults.first { $0.id == "claude-code" }!
        claude.command = ""
        claude.flags["dangerously-skip-permissions"] = .bool(true)
        XCTAssertEqual(
            HarnessSchemas.composedCommand(for: claude),
            "--dangerously-skip-permissions"
        )
    }

    func testGhosttyIntegrationCreateAndFocus() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GHOSTTY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_GHOSTTY_INTEGRATION=1 to create and focus a real Ghostty window.")
        }

        let controller = await AppleScriptGhosttyController()
        let created = try await controller.createWindow(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            initialInput: nil,
            bringToFront: true
        )

        _ = try await controller.focusTerminal(
            windowId: created.windowId,
            tabId: created.tabId,
            terminalId: created.terminalId
        )
    }

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private actor FakeGhosttyController: GhosttyControlling {
    private var counter = 0
    private var createdWorkingDirectories: [String] = []
    private var lastInitialInput: String?
    private var shouldFailFocus = false

    func setShouldFailFocus(_ value: Bool) {
        shouldFailFocus = value
    }

    func createdWorkingDirectoriesSnapshot() -> [String] {
        createdWorkingDirectories
    }

    func lastInitialInputSnapshot() -> String? {
        lastInitialInput
    }

    private(set) var lastBringToFront: Bool?

    func createWindow(
        workingDirectory: String,
        initialInput: String?,
        bringToFront: Bool
    ) async throws -> CreatedGhosttySurface {
        try Task.checkCancellation()

        counter += 1
        createdWorkingDirectories.append(workingDirectory)
        lastInitialInput = initialInput
        lastBringToFront = bringToFront

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
