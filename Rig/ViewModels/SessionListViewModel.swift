import Foundation
import SwiftUI

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published private(set) var sessions: [GhosttySession] = []
    @Published var selectedSessionID: GhosttySession.ID?
    @Published private(set) var isCreatingSession = false
    @Published private(set) var lastError: String?

    private let controller: GhosttyControlling
    private let store: SessionStore
    private let homeDirectory: String
    private var nextSessionOrdinal = 1
    private var hasStarted = false
    private var persistedSnapshot: PersistedSessions?
    private var focusTask: Task<Void, Never>?
    private var pendingFocusSessionID: GhosttySession.ID?

    init(
        controller: GhosttyControlling,
        store: SessionStore,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.controller = controller
        self.store = store
        self.homeDirectory = homeDirectory
    }

    deinit {
        focusTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            let persisted = try store.load()
            sessions = persisted.sessions
            nextSessionOrdinal = max(persisted.nextSessionOrdinal, nextOrdinal(after: sessions))
            persistedSnapshot = persisted
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createSession(workingDirectory: String? = nil) async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        focusTask?.cancel()
        pendingFocusSessionID = nil
        defer { isCreatingSession = false }

        do {
            let ordinal = nextSessionOrdinal
            let label = "Session \(ordinal)"
            let cwd = workingDirectory ?? homeDirectory
            let createdSurface = try await controller.createWindow(workingDirectory: cwd)
            nextSessionOrdinal = ordinal + 1

            let session = GhosttySession(
                id: UUID(),
                label: label,
                ghosttyWindowId: createdSurface.windowId,
                ghosttyTabId: createdSurface.tabId,
                ghosttyTerminalId: createdSurface.terminalId
            )

            withAnimation(.snappy(duration: 0.22)) {
                sessions.append(session)
                selectedSessionID = session.id
            }

            try persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func focus(_ session: GhosttySession) async {
        guard sessions.contains(where: { $0.id == session.id }) else { return }

        selectedSessionID = session.id

        do {
            try Task.checkCancellation()
            _ = try await controller.focusTerminal(
                windowId: session.ghosttyWindowId,
                tabId: session.ghosttyTabId,
                terminalId: session.ghosttyTerminalId
            )
            try Task.checkCancellation()
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

        do {
            try persist()
        } catch {
            lastError = error.localizedDescription
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

        let currentIndex = selectedSessionID.flatMap { selectedID in
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

    private func persist() throws {
        let state = PersistedSessions(
            nextSessionOrdinal: nextSessionOrdinal,
            sessions: sessions
        )

        guard state != persistedSnapshot else { return }

        try store.save(state)
        persistedSnapshot = state
    }

    private func nextOrdinal(after sessions: [GhosttySession]) -> Int {
        let maximumExistingNumber = sessions.compactMap { session -> Int? in
            guard session.label.hasPrefix("Session ") else { return nil }
            return Int(session.label.dropFirst("Session ".count))
        }
        .max() ?? 0

        return maximumExistingNumber + 1
    }
}
