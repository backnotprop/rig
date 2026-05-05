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

    func testShellRunnerResolveReturnsNilForUnknownTool() {
        XCTAssertNil(ShellRunner.resolve("definitely-not-a-real-tool-xyz"))
    }

    func testShellRunnerResolveFindsCommonTool() {
        // `ls` exists at /bin/ls on every macOS. If $PATH is empty in the
        // test runner this still has to be found — we don't fall back to /bin
        // explicitly, so this also documents the fallback set.
        let path = ShellRunner.resolve("ls")
        XCTAssertNotNil(path)
    }

    func testGitHubProviderDecodesIssueRows() {
        // A condensed but real-shape fixture from `gh issue list --json
        // number,title,url,author,updatedAt`. Pinned so a future schema
        // change in `gh` breaks the test loudly rather than silently
        // emitting empty subtitles.
        let json = """
        [
          {
            "number": 42,
            "title": "Crash on launch when config is empty",
            "url": "https://github.com/example/repo/issues/42",
            "updatedAt": "2026-04-30T12:34:56Z",
            "author": { "login": "alice" }
          },
          {
            "number": 7,
            "title": "Deleted-author edge case",
            "url": "https://github.com/example/repo/issues/7",
            "updatedAt": "2026-04-29T08:00:00Z",
            "author": {}
          }
        ]
        """

        let provider = GitHubReferenceProvider()
        let items = provider.decodeRows(json, flavor: "issue")

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "issue-42")
        XCTAssertEqual(items[0].title, "Crash on launch when config is empty")
        XCTAssertEqual(items[0].url.absoluteString, "https://github.com/example/repo/issues/42")
        XCTAssertNotNil(items[0].subtitle)
        XCTAssertTrue(items[0].subtitle?.contains("#42") == true)
        XCTAssertTrue(items[0].subtitle?.contains("@alice") == true)

        XCTAssertEqual(items[1].id, "issue-7")
        // Deleted author — subtitle should still render but skip the @login part.
        XCTAssertTrue(items[1].subtitle?.contains("#7") == true)
        XCTAssertFalse(items[1].subtitle?.contains("@") == true)
    }

    func testGitHubParseRepoIdentifierAcceptsCommonShapes() {
        let cases: [(input: String, expected: (String, String))] = [
            ("anthropics/claude-code", ("anthropics", "claude-code")),
            ("https://github.com/anthropics/claude-code", ("anthropics", "claude-code")),
            ("https://github.com/anthropics/claude-code.git", ("anthropics", "claude-code")),
            ("https://github.com/anthropics/claude-code/pull/123", ("anthropics", "claude-code")),
            ("github.com/anthropics/claude-code", ("anthropics", "claude-code")),
            ("git@github.com:anthropics/claude-code.git", ("anthropics", "claude-code")),
            ("  anthropics/claude-code  ", ("anthropics", "claude-code")),
            ("https://github.com/anthropics/claude-code?tab=readme", ("anthropics", "claude-code")),
        ]
        for (input, expected) in cases {
            let parsed = GitHubReferenceProvider.parseRepoIdentifier(input)
            XCTAssertNotNil(parsed, "Failed to parse: \(input)")
            XCTAssertEqual(parsed?.owner, expected.0, "Wrong owner for: \(input)")
            XCTAssertEqual(parsed?.name, expected.1, "Wrong name for: \(input)")
        }
    }

    func testGitHubParseRepoIdentifierRejectsGarbage() {
        for input in ["", "   ", "not a repo", "owner", "/", "/owner/name", " /name"] {
            XCTAssertNil(
                GitHubReferenceProvider.parseRepoIdentifier(input),
                "Should reject: \(input)"
            )
        }
    }

    func testGitHubProviderDecodesPRRows() {
        let json = """
        [
          {
            "number": 99,
            "title": "Refactor session list",
            "url": "https://github.com/example/repo/pull/99",
            "updatedAt": "2026-04-30T12:34:56Z",
            "author": { "login": "bob" },
            "isDraft": false
          }
        ]
        """

        let provider = GitHubReferenceProvider()
        let items = provider.decodeRows(json, flavor: "pr")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "pr-99")
        XCTAssertEqual(items[0].url.absoluteString, "https://github.com/example/repo/pull/99")
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

    func closeWindow(windowId: String) async throws {}
}
