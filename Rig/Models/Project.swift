import Foundation

struct Project: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var path: String

    var name: String {
        (path as NSString).lastPathComponent
    }
}

struct PersistedProjects: Codable, Equatable {
    var projects: [Project]
    var recentOrder: [UUID]
    var selectedProjectID: UUID?

    static let empty = PersistedProjects(projects: [], recentOrder: [], selectedProjectID: nil)
}
