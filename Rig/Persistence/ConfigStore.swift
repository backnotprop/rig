import AppKit
import Combine
import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: RigConfig

    private let storeURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(storeURL: URL? = nil) {
        let resolvedURL = storeURL ?? Self.defaultStoreURL
        self.storeURL = resolvedURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let loaded: RigConfig
        do {
            loaded = try Self.loadOrMigrate(at: resolvedURL, decoder: decoder, encoder: encoder)
        } catch {
            loaded = .firstRun()
        }
        config = loaded

        $config
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)
    }

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Rig", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func loadOrMigrate(
        at url: URL,
        decoder: JSONDecoder,
        encoder: JSONEncoder
    ) throws -> RigConfig {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try decoder.decode(RigConfig.self, from: data)
        }

        // Migration: fold legacy projects.json into the new config if present.
        var seed = RigConfig.firstRun()
        let legacyURL = dir.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: legacyURL.path),
            let data = try? Data(contentsOf: legacyURL),
            let legacy = try? decoder.decode(LegacyProjects.self, from: data)
        {
            seed.projects = legacy.projects
            seed.preferences.recentProjectIDs = legacy.recentOrder
            seed.preferences.selectedProjectID = legacy.selectedProjectID
            try? FileManager.default.removeItem(at: legacyURL)
        }

        // Sessions are no longer persisted.
        let sessionsURL = dir.appendingPathComponent("sessions.json")
        try? FileManager.default.removeItem(at: sessionsURL)

        let data = try encoder.encode(seed)
        try data.write(to: url, options: [.atomic])
        return seed
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            try? self.saveNow()
        }
    }

    private func saveNow() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(config)
        try data.write(to: storeURL, options: [.atomic])
    }

    /// Cancels any pending debounced save and writes immediately. Called on app
    /// termination so edits made within the debounce window aren't lost. Tests also
    /// use this to bypass the 500ms wait.
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        try? saveNow()
    }
}

private struct LegacyProjects: Codable {
    var projects: [Project]
    var recentOrder: [UUID]
    var selectedProjectID: UUID?
}

// MARK: - Project queries / actions
extension ConfigStore {
    var selectedProject: Project? {
        guard let id = config.preferences.selectedProjectID else { return nil }
        return config.projects.first { $0.id == id }
    }

    var recentProjects: [Project] {
        config.preferences.recentProjectIDs.prefix(5).compactMap { id in
            config.projects.first { $0.id == id }
        }
    }

    var recentProjectIDs: Set<UUID> {
        Set(config.preferences.recentProjectIDs.prefix(5))
    }

    var allProjectsByRecency: [Project] {
        let recents = config.preferences.recentProjectIDs.compactMap { id in
            config.projects.first { $0.id == id }
        }
        let recentSet = Set(recents.map(\.id))
        let rest = config.projects
            .filter { !recentSet.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return recents + rest
    }

    func selectProject(id: UUID) {
        guard config.projects.contains(where: { $0.id == id }) else { return }
        config.preferences.selectedProjectID = id
        moveProjectToFrontOfRecents(id)
    }

    func addProject(path: String) {
        if let existing = config.projects.first(where: { $0.path == path }) {
            selectProject(id: existing.id)
            return
        }
        let project = Project(id: UUID(), path: path, label: nil)
        config.projects.append(project)
        config.preferences.selectedProjectID = project.id
        moveProjectToFrontOfRecents(project.id)
    }

    func addProjectByPickingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a project folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(path: url.path)
    }

    func clearProjectSelection() {
        config.preferences.selectedProjectID = nil
    }

    func removeProject(id: UUID) {
        config.projects.removeAll { $0.id == id }
        config.preferences.recentProjectIDs.removeAll { $0 == id }
        if config.preferences.selectedProjectID == id {
            config.preferences.selectedProjectID = nil
        }
    }

    private func moveProjectToFrontOfRecents(_ id: UUID) {
        var recents = config.preferences.recentProjectIDs
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        config.preferences.recentProjectIDs = recents
    }
}

// MARK: - Harness queries
extension ConfigStore {
    var enabledHarnesses: [Harness] {
        config.harnesses.filter(\.enabled)
    }

    func harness(id: String) -> Harness? {
        config.harnesses.first { $0.id == id }
    }
}

// MARK: - Saved prompts
extension ConfigStore {
    /// Prompts in the order the dock should render them, given the current
    /// sort preference. `.custom` is array-order; `.created` is newest-first;
    /// `.lastUsed` puts recently-used ones up front and sinks unused ones to
    /// the bottom in their stored order (so the user's hand-picked order
    /// still shows for never-used prompts).
    var displayPrompts: [SavedPrompt] {
        let prompts = config.prompts
        switch config.preferences.promptSortOrder {
        case .lastUsed:
            return prompts.sorted { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (l?, r?): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return false
                }
            }
        case .created:
            return prompts.sorted { $0.createdAt > $1.createdAt }
        case .custom:
            return prompts
        }
    }

    @discardableResult
    func addPrompt() -> SavedPrompt.ID {
        let prompt = SavedPrompt()
        config.prompts.append(prompt)
        return prompt.id
    }

    func removePrompt(id: SavedPrompt.ID) {
        config.prompts.removeAll { $0.id == id }
    }

    /// Apply a List drag-reorder. We commit whatever the user is *currently
    /// looking at* (post-sort) as the new array order, then perform the move
    /// against that — otherwise dragging row 1 down while in `.lastUsed`
    /// would shuffle some unrelated underlying-array entry. Flipping to
    /// `.custom` is the whole point: the gesture is the source of truth now.
    func movePromptsInVisibleOrder(
        currentlyVisible: [SavedPrompt],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) {
        var ordered = currentlyVisible
        ordered.move(fromOffsets: source, toOffset: destination)
        config.prompts = ordered
        config.preferences.promptSortOrder = .custom
    }

    func recordPromptUse(id: SavedPrompt.ID) {
        guard let idx = config.prompts.firstIndex(where: { $0.id == id }) else { return }
        config.prompts[idx].lastUsedAt = .now
    }
}

// MARK: - Reference scopes (per-provider recents)
extension ConfigStore {
    private static let recentScopeLimit = 5

    func recentScopes(providerID: String) -> [ReferenceScope] {
        config.preferences.recentScopesByProvider[providerID] ?? []
    }

    /// Bumps `scope` to the front of the provider's recent list (deduped),
    /// capped at 5. Called on user-driven picks only — auto-detected scopes
    /// stay out so "recent" stays meaningful.
    func recordRecentScope(providerID: String, scope: ReferenceScope) {
        var list = config.preferences.recentScopesByProvider[providerID] ?? []
        list.removeAll { $0.id == scope.id }
        list.insert(scope, at: 0)
        if list.count > Self.recentScopeLimit {
            list = Array(list.prefix(Self.recentScopeLimit))
        }
        config.preferences.recentScopesByProvider[providerID] = list
    }
}
