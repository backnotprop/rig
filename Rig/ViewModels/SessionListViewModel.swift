import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var sessions: [GhosttySession] = []
    @Published var selectedSessionID: GhosttySession.ID?
    @Published private(set) var isCreatingSession = false
    @Published private(set) var lastError: String?
    @Published private(set) var serversBySession: [UUID: [DetectedServer]] = [:]

    private let controller: GhosttyControlling
    private let homeDirectory: String
    let spaceSwitcher = SpaceSwitcher()
    let portMonitor = PortMonitor()
    private var portMonitorSink: AnyCancellable?
    var instantSpaceSwitching = true
    /// Called after a session switch to tuck the sidebar. Set by AppDelegate.
    var onSessionSwitched: (() -> Void)?
    private var nextSessionOrdinal = 1
    private var hasStarted = false
    private var focusTask: Task<Void, Never>?
    private var pendingFocusSessionID: GhosttySession.ID?
    private var isDummyDataMode: Bool {
        ProcessInfo.processInfo.environment["RIG_DUMMY_DATA"] == "1"
    }

    init(
        controller: GhosttyControlling,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.controller = controller
        self.homeDirectory = homeDirectory
    }

    deinit {
        focusTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        portMonitor.startMonitoring()
        portMonitorSink = portMonitor.$serversBySession.sink { [weak self] newValue in
            self?.serversBySession = newValue
        }

        if isDummyDataMode {
            seedDummyData()
        }
    }

    private func seedDummyData() {
        let dummySessions: [(label: String, servers: [DetectedServer])] = [
            ("π - scratch", [
                DetectedServer(id: "d1|3000", port: 3000, processName: "node"),
                DetectedServer(id: "d1|5173", port: 5173, processName: "vite"),
            ]),
            ("✳ Review PR changes", [
                DetectedServer(id: "d2|8080", port: 8080, processName: "python3"),
            ]),
            ("claude - rig", []),
            ("codex - api-service", [
                DetectedServer(id: "d4|4000", port: 4000, processName: "node"),
                DetectedServer(id: "d4|4001", port: 4001, processName: "node"),
                DetectedServer(id: "d4|9229", port: 9229, processName: "node"),
            ]),
            ("opencode - frontend", []),
        ]

        for (i, dummy) in dummySessions.enumerated() {
            let id = UUID()
            let session = GhosttySession(
                id: id,
                label: dummy.label,
                ghosttyWindowId: "dummy-win-\(i)",
                ghosttyTabId: "dummy-tab-\(i)",
                ghosttyTerminalId: "dummy-term-\(i)"
            )
            sessions.append(session)
            if !dummy.servers.isEmpty {
                serversBySession[id] = dummy.servers
            }
        }
        selectedSessionID = sessions.first?.id
    }

    func createSession(
        workingDirectory: String? = nil,
        command: String? = nil,
        harnessID: String? = nil,
        projectID: UUID? = nil,
        labelPrefix: String = "Session",
        bringToFront: Bool = true
    ) async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        focusTask?.cancel()
        pendingFocusSessionID = nil
        defer { isCreatingSession = false }

        do {
            let ordinal = nextSessionOrdinal
            let label = "\(labelPrefix) \(ordinal)"
            let cwd = workingDirectory ?? homeDirectory
            let sessionID = UUID()
            let createdSurface = try await controller.createWindow(
                workingDirectory: cwd,
                initialInput: command,
                environmentVariables: [
                    "\(PortMonitor.sessionEnvironmentKey)=\(sessionID.uuidString)"
                ],
                bringToFront: bringToFront
            )
            nextSessionOrdinal = ordinal + 1

            // Brief pause so the window compositor registers the new window
            // before we try to capture its CGWindowID.
            try? await Task.sleep(for: .milliseconds(150))

            let cgWID = SpaceSwitcher.ghosttyPID.flatMap {
                SpaceSwitcher.newestWindowID(ownerPID: $0)
            } ?? 0
            let session = GhosttySession(
                id: sessionID,
                label: label,
                harnessID: harnessID,
                projectID: projectID,
                ghosttyWindowId: createdSurface.windowId,
                ghosttyTabId: createdSurface.tabId,
                ghosttyTerminalId: createdSurface.terminalId,
                isBackgrounded: !bringToFront,
                cgWindowID: cgWID
            )

            if bringToFront,
               !ManagedGhosttyWindowRegistry.registerFocusedWindow(sessionID: sessionID),
               cgWID != 0 {
                ManagedGhosttyWindowRegistry.register(sessionID: sessionID, windowID: cgWID)
            }

            portMonitor.registerSession(sessionID)

            withAnimation(.snappy(duration: 0.22)) {
                sessions.append(session)
                selectedSessionID = session.id
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func focus(_ session: GhosttySession) async {
        guard sessions.contains(where: { $0.id == session.id }) else { return }

        selectedSessionID = session.id

        if instantSpaceSwitching && session.cgWindowID != 0 {
            ManagedGhosttyWindowRegistry.register(sessionID: session.id, windowID: session.cgWindowID)
            onSessionSwitched?()
            spaceSwitcher.switchToSpaceOf(windowID: session.cgWindowID)
            return
        }

        do {
            try Task.checkCancellation()
            _ = try await controller.focusTerminal(
                windowId: session.ghosttyWindowId,
                tabId: session.ghosttyTabId,
                terminalId: session.ghosttyTerminalId
            )
            try? await Task.sleep(for: .milliseconds(120))
            ManagedGhosttyWindowRegistry.registerFocusedWindow(sessionID: session.id)
            try Task.checkCancellation()
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].isBackgrounded = false
            }
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requestFocus(_ session: GhosttySession) {
        guard pendingFocusSessionID != session.id else { return }

        pendingFocusSessionID = session.id
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            await self?.focus(session)
            self?.clearPendingFocus(if: session.id)
        }
    }

    func openServerInSharedSpace(_ server: DetectedServer, for session: GhosttySession) {
        if isDummyDataMode {
            NSWorkspace.shared.open(server.url)
            return
        }

        Task {
            do {
                try await WindowArranger.openURLInSharedSpace(server.url, beside: session)
                lastError = nil
            } catch {
                NSWorkspace.shared.open(server.url)
                lastError = error.localizedDescription
            }
        }
    }

    func openServerInNativeSplitView(_ server: DetectedServer, for session: GhosttySession) {
        if isDummyDataMode {
            NSWorkspace.shared.open(server.url)
            return
        }

        Task {
            do {
                try await WindowArranger.openURLInNativeSplitView(server.url, beside: session)
                lastError = nil
            } catch {
                NSWorkspace.shared.open(server.url)
                lastError = error.localizedDescription
            }
        }
    }

    func arrange(sessions: [GhosttySession], layout: WindowArranger.Layout) {
        if isDummyDataMode {
            return
        }

        Task {
            do {
                try await WindowArranger.arrange(sessions: sessions, layout: layout)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func focusSelected() async {
        guard let selectedSession else { return }
        await focus(selectedSession)
    }

    func focusSession(at index: Int) async {
        guard sessions.indices.contains(index) else { return }
        await focus(sessions[index])
    }

    func remove(_ session: GhosttySession) {
        portMonitor.removeSession(session.id)
        withAnimation(.snappy(duration: 0.18)) {
            sessions.removeAll { $0.id == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = sessions.first?.id
            }
        }
        Task {
            await closeGhosttySessions([session])
        }
    }

    func removeAll() {
        let toClose = sessions
        portMonitor.removeAll()
        withAnimation(.snappy(duration: 0.18)) {
            sessions.removeAll()
            selectedSessionID = nil
        }
        Task {
            await closeGhosttySessions(toClose)
        }
    }

    func removeSelected() {
        guard
            let selectedSessionID,
            let selectedSession = sessions.first(where: { $0.id == selectedSessionID })
        else {
            return
        }
        remove(selectedSession)
    }

    func select(_ session: GhosttySession) {
        selectedSessionID = session.id
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        guard !sessions.isEmpty else { return }

        let currentIndex =
            selectedSessionID.flatMap { selectedID in
                sessions.firstIndex { $0.id == selectedID }
            } ?? 0

        switch direction {
        case .up:
            selectedSessionID = sessions[max(0, currentIndex - 1)].id
        case .down:
            selectedSessionID = sessions[min(sessions.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    func dismissError() {
        lastError = nil
    }

    /// Refreshes session labels from Ghostty's current window titles.
    /// Called when Rig reveals so the list always shows up-to-date names.
    func refreshSessionTitles() {
        let windowIDs = sessions.map(\.ghosttyWindowId)
        guard !windowIDs.isEmpty else { return }

        let idList = windowIDs.map { "\"\($0)\"" }.joined(separator: ", ")
        let source = """
        tell application "Ghostty"
            set targetIds to {\(idList)}
            set output to ""
            set winCount to 0
            try
                set winCount to count of windows
            end try
            repeat with winIdx from 1 to winCount
                try
                    set winRef to window winIdx
                    set winId to id of winRef as text
                    if targetIds contains winId then
                        set winTitle to name of winRef as text
                        set output to output & winId & "|" & winTitle & linefeed
                    end if
                end try
            end repeat
            return output
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return }
        let result = script.executeAndReturnError(&errorInfo)
        guard let raw = result.stringValue else { return }

        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let winId = String(parts[0])
            let title = String(parts[1])
            if let idx = sessions.firstIndex(where: { $0.ghosttyWindowId == winId }) {
                if sessions[idx].label != title {
                    sessions[idx].label = title
                }
            }
        }
    }

    private var selectedSession: GhosttySession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    private func clearPendingFocus(if sessionID: GhosttySession.ID) {
        if pendingFocusSessionID == sessionID {
            pendingFocusSessionID = nil
        }
    }

    private func closeGhosttySessions(_ sessions: [GhosttySession]) async {
        guard !sessions.isEmpty else { return }

        await WindowArranger.exitNativeFullScreen(sessions: sessions)

        for session in sessions {
            do {
                try await controller.closeWindow(windowId: session.ghosttyWindowId)
                lastError = nil
            } catch where error.isMissingManagedGhosttySurface {
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }

            ManagedGhosttyWindowRegistry.remove(session.id)
        }
    }
}
