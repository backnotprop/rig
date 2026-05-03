import AppKit
import Foundation
import SwiftUI

@MainActor
final class ProjectsViewModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var recentOrder: [UUID] = []
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var lastSnapshot: PersistedProjects?
    private var hasStarted = false

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let supportURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Rig", isDirectory: true)
            self.storeURL = supportURL.appendingPathComponent("projects.json")
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        load()
    }

    var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var recentProjects: [Project] {
        recentOrder.prefix(5).compactMap { id in
            projects.first { $0.id == id }
        }
    }

    var recentProjectIDs: Set<UUID> {
        Set(recentOrder.prefix(5))
    }

    var allProjectsByRecency: [Project] {
        let inRecent = recentOrder.compactMap { id in projects.first { $0.id == id } }
        let recentSet = Set(inRecent.map(\.id))
        let rest = projects
            .filter { !recentSet.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return inRecent + rest
    }

    func selectProject(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        moveToFrontOfRecent(id)
        persist()
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

    func addProject(path: String) {
        if let existing = projects.first(where: { $0.path == path }) {
            selectProject(id: existing.id)
            return
        }
        let project = Project(id: UUID(), path: path)
        projects.append(project)
        selectedProjectID = project.id
        moveToFrontOfRecent(project.id)
        persist()
    }

    private func moveToFrontOfRecent(_ id: UUID) {
        recentOrder.removeAll { $0 == id }
        recentOrder.insert(id, at: 0)
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                lastSnapshot = .empty
                return
            }
            let data = try Data(contentsOf: storeURL)
            let state = try decoder.decode(PersistedProjects.self, from: data)
            projects = state.projects
            recentOrder = state.recentOrder
            selectedProjectID = state.selectedProjectID
            lastSnapshot = state
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist() {
        let state = PersistedProjects(
            projects: projects,
            recentOrder: recentOrder,
            selectedProjectID: selectedProjectID
        )
        guard state != lastSnapshot else { return }
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: storeURL, options: [.atomic])
            lastSnapshot = state
        } catch {
            lastError = error.localizedDescription
        }
    }
}
