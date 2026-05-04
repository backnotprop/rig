import Foundation

struct RigConfig: Codable, Equatable {
    var version: Int
    var harnesses: [Harness]
    var projects: [Project]
    var preferences: Preferences
}

struct Preferences: Codable, Equatable {
    var autohideRevealDelay: TimeInterval = 0.6
    var autohideAnimationDuration: TimeInterval = 0.4
    var autohideHideGracePeriod: TimeInterval = 0.3
    var autohideTriggerWidth: Double = 1
    var recentProjectIDs: [UUID] = []
    var selectedProjectID: UUID? = nil
}

extension RigConfig {
    static func firstRun() -> RigConfig {
        RigConfig(
            version: 1,
            harnesses: Harness.builtinDefaults,
            projects: [],
            preferences: Preferences()
        )
    }
}
