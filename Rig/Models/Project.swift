import Foundation

struct Project: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var path: String
    var label: String?

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return (path as NSString).lastPathComponent
    }
}
