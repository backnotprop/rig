import Foundation
import SwiftUI

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var sessions: [GhosttySession] = []
    @Published var selectedSessionID: GhosttySession.ID?
    @Published private(set) var isCreatingSession = false
    @Published private(set) var lastError: String?

    private let controller: GhosttyControlling
    private let homeDirectory: String
    let spaceSwitcher = SpaceSwitcher()
    var instantSpaceSwitching = true
    /// Called after a session switch to tuck the sidebar. Set by AppDelegate.
    var onSessionSwitched: (() -> Void)?
    private var nextSessionOrdinal = 1
    private var hasStarted = false
    private var focusTask: Task<Void, Never>?
    private var pendingFocusSessionID: GhosttySession.ID?

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
            let createdSurface = try await controller.createWindow(
                workingDirectory: cwd,
                initialInput: command,
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
                id: UUID(),
                label: label,
                harnessID: harnessID,
                projectID: projectID,
                ghosttyWindowId: createdSurface.windowId,
                ghosttyTabId: createdSurface.tabId,
                ghosttyTerminalId: createdSurface.terminalId,
                isBackgrounded: !bringToFront,
                cgWindowID: cgWID
            )

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

    func focusSelected() async {
        guard let selectedSession else { return }
        await focus(selectedSession)
    }

    func focusSession(at index: Int) async {
        guard sessions.indices.contains(index) else { return }
        await focus(sessions[index])
    }

    func remove(_ session: GhosttySession) {
        withAnimation(.snappy(duration: 0.18)) {
            sessions.removeAll { $0.id == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = sessions.first?.id
            }
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

    private var selectedSession: GhosttySession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    private func clearPendingFocus(if sessionID: GhosttySession.ID) {
        if pendingFocusSessionID == sessionID {
            pendingFocusSessionID = nil
        }
    }
}
