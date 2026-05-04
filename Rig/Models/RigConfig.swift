import Foundation

struct RigConfig: Codable, Equatable {
    var version: Int
    var harnesses: [Harness]
    var projects: [Project]
    var prompts: [SavedPrompt]
    var preferences: Preferences

    private enum CodingKeys: String, CodingKey {
        case version, harnesses, projects, prompts, preferences
    }

    init(
        version: Int,
        harnesses: [Harness],
        projects: [Project],
        prompts: [SavedPrompt],
        preferences: Preferences
    ) {
        self.version = version
        self.harnesses = harnesses
        self.projects = projects
        self.prompts = prompts
        self.preferences = preferences
    }

    // Tolerate older configs that predate `prompts`. Synthesized Codable would
    // otherwise throw on the missing key — bumping `version` and migrating
    // would be heavier-handed for a purely additive change.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.harnesses = try c.decode([Harness].self, forKey: .harnesses)
        self.projects = try c.decode([Project].self, forKey: .projects)
        self.prompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .prompts) ?? []
        self.preferences = try c.decode(Preferences.self, forKey: .preferences)
    }
}

struct Preferences: Codable, Equatable {
    var autohideRevealDelay: TimeInterval = 0.6
    var autohideAnimationDuration: TimeInterval = 0.4
    var autohideHideGracePeriod: TimeInterval = 0.3
    var autohideTriggerWidth: Double = 1
    var recentProjectIDs: [UUID] = []
    var selectedProjectID: UUID? = nil
    var promptSortOrder: PromptSortOrder = .lastUsed

    private enum CodingKeys: String, CodingKey {
        case autohideRevealDelay, autohideAnimationDuration, autohideHideGracePeriod
        case autohideTriggerWidth, recentProjectIDs, selectedProjectID, promptSortOrder
    }

    init() {}

    // Same backward-compat reasoning as RigConfig.init(from:): every key is
    // optional on decode so adding a new preference doesn't invalidate older
    // configs on the user's disk.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autohideRevealDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .autohideRevealDelay) ?? 0.6
        self.autohideAnimationDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .autohideAnimationDuration) ?? 0.4
        self.autohideHideGracePeriod = try c.decodeIfPresent(TimeInterval.self, forKey: .autohideHideGracePeriod) ?? 0.3
        self.autohideTriggerWidth = try c.decodeIfPresent(Double.self, forKey: .autohideTriggerWidth) ?? 1
        self.recentProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .recentProjectIDs) ?? []
        self.selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        self.promptSortOrder = try c.decodeIfPresent(PromptSortOrder.self, forKey: .promptSortOrder) ?? .lastUsed
    }
}

extension RigConfig {
    static func firstRun() -> RigConfig {
        RigConfig(
            version: 1,
            harnesses: Harness.builtinDefaults,
            projects: [],
            prompts: [],
            preferences: Preferences()
        )
    }
}
