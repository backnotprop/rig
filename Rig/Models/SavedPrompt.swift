import Foundation

/// A reusable prompt the user keeps in their library and pipes into a harness on
/// launch. `marker` is the chip glyph (letter, number, emoji — capped at 2
/// grapheme clusters at the input layer), `body` is the actual text, `tint` is
/// the user-picked chip color.
struct SavedPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var marker: String
    var body: String
    var tint: HexColor
    var createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        marker: String = "",
        body: String = "",
        tint: HexColor = SavedPrompt.defaultTint,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.marker = marker
        self.body = body
        self.tint = tint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Starting chip color for newly created prompts. The user is expected to
    /// change it via the Settings color picker; this is just a non-ugly default.
    static let defaultTint = HexColor("#4F6BFF")
}

/// How the saved-prompt dock orders chips in the launcher drawer. `.custom`
/// uses the array's order as-is, so a drag in Settings is the source of truth.
enum PromptSortOrder: String, Codable, CaseIterable, Equatable {
    case lastUsed
    case created
    case custom

    var label: String {
        switch self {
        case .lastUsed: "Recent"
        case .created: "Created"
        case .custom: "Custom"
        }
    }
}

extension String {
    /// Truncates to at most `max` grapheme clusters. Used for prompt markers,
    /// where one emoji ("👨‍💻") is one user-perceived character even though
    /// it's many UTF-8 bytes — Swift's `String.prefix` already iterates by
    /// grapheme cluster, so this is the right primitive.
    func truncatedToGraphemes(_ max: Int) -> String {
        guard count > max else { return self }
        return String(prefix(max))
    }
}
