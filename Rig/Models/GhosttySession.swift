import Foundation

struct GhosttySession: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var ghosttyWindowId: String
    var ghosttyTabId: String
    var ghosttyTerminalId: String
}

struct PersistedSessions: Codable, Equatable {
    var nextSessionOrdinal: Int
    var sessions: [GhosttySession]

    static let empty = PersistedSessions(nextSessionOrdinal: 1, sessions: [])
}
