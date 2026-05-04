import Foundation

/// A sub-type within a `ReferenceProvider`. GitHub has issues + PRs (and
/// eventually discussions); Linear has issues + projects; etc. The drawer
/// renders a segmented picker over `provider.flavors` so adding a flavor is
/// just data.
struct ReferenceFlavor: Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let symbolName: String
}

/// A single fetched item (one issue, one PR, one ticket). The drawer renders
/// these as rows; tapping appends `url.absoluteString` to the prompt.
struct ReferenceItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let url: URL
}

/// What a provider hands back from `fetch`. Three terminal states by design —
/// either we got items, we know up front there's nothing to fetch (no scope
/// resolved), or the underlying tool errored. We surface the tool's own
/// stderr in `.error` rather than build a remedy ladder.
enum ProviderResult: Equatable {
    case items([ReferenceItem])
    case noContext(message: String)
    case error(String)
}

/// A sub-grouping a provider supports — GitHub repo, Linear team, Notion
/// database, Jira project. `id` is the canonical identifier the provider's
/// fetch consumes (e.g., `"anthropics/claude-code"`); `displayName` is what
/// the user sees (often the same).
struct ReferenceScope: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let displayName: String
}

/// Outcome of asking a provider to validate user-typed input as a scope.
enum ScopeResolution: Equatable {
    case ok(ReferenceScope)
    case error(String)
}

protocol ReferenceProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var iconAssetName: String { get }
    var flavors: [ReferenceFlavor] { get }

    /// Label for the scope concept this provider exposes ("Repo", "Team",
    /// "Database", "Project"). `nil` means the provider has no scope and the
    /// panel skips the scope row.
    var scopeKind: String? { get }

    /// Best guess at the right scope for the current project context. GitHub
    /// runs `gh repo view`; Linear might read a project marker; etc. Returns
    /// nil when nothing can be detected (no project, no remote).
    func detectedScope(projectPath: String?) async -> ReferenceScope?

    /// Validates user-typed input (e.g. `owner/name`, a URL) and returns the
    /// canonical scope, or an error message to render inline.
    func resolveScope(_ identifier: String) async -> ScopeResolution

    /// Fetch items. `scope` is non-nil whenever `scopeKind` is non-nil — the
    /// panel guarantees a scope before calling fetch on a scoped provider.
    func fetch(
        flavor: ReferenceFlavor.ID,
        scope: ReferenceScope?,
        projectPath: String?
    ) async -> ProviderResult
}

/// Single source of truth for which providers exist. Drawer iterates this to
/// render one button per provider; new providers slot in by appending here.
@MainActor
enum ReferenceRegistry {
    static let providers: [any ReferenceProvider] = [
        GitHubReferenceProvider()
    ]
}
