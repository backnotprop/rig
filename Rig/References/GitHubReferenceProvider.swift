import Foundation

struct GitHubReferenceProvider: ReferenceProvider {
    let id = "github"
    let displayName = "GitHub"
    let iconAssetName = "GitHub"
    let scopeKind: String? = "Repo"

    let flavors: [ReferenceFlavor] = [
        ReferenceFlavor(
            id: "issue",
            label: "Issues",
            symbolName: "exclamationmark.circle"
        ),
        ReferenceFlavor(
            id: "pr",
            label: "PRs",
            symbolName: "arrow.triangle.pull"
        )
    ]

    // MARK: - Scope detection / resolution

    func detectedScope(projectPath: String?) async -> ReferenceScope? {
        guard let projectPath, FileManager.default.fileExists(atPath: projectPath) else {
            return nil
        }
        let gitDir = (projectPath as NSString).appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: gitDir) { return nil }
        guard let gh = ShellRunner.resolve("gh") else { return nil }

        do {
            let result = try await ShellRunner.run(
                executable: gh,
                args: ["repo", "view", "--json", "nameWithOwner"],
                cwd: projectPath
            )
            if result.exitCode != 0 { return nil }
            return decodeNameWithOwner(result.stdout).map {
                ReferenceScope(id: $0, displayName: $0)
            }
        } catch {
            return nil
        }
    }

    func resolveScope(_ identifier: String) async -> ScopeResolution {
        guard let parsed = Self.parseRepoIdentifier(identifier) else {
            return .error("Use owner/name or a github.com URL.")
        }
        let canonical = "\(parsed.owner)/\(parsed.name)"

        guard let gh = ShellRunner.resolve("gh") else {
            return .error("gh: command not found")
        }

        do {
            let result = try await ShellRunner.run(
                executable: gh,
                args: ["repo", "view", canonical, "--json", "nameWithOwner"]
            )
            if result.exitCode != 0 {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .error(stderr.isEmpty ? "Repo not found" : stderr)
            }
            let resolved = decodeNameWithOwner(result.stdout) ?? canonical
            return .ok(ReferenceScope(id: resolved, displayName: resolved))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Fetch

    func fetch(
        flavor: ReferenceFlavor.ID,
        scope: ReferenceScope?,
        projectPath: String?
    ) async -> ProviderResult {
        guard let scope else {
            return .noContext(message: "Select a repo")
        }

        guard let gh = ShellRunner.resolve("gh") else {
            return .error("gh: command not found")
        }

        let baseArgs: [String]
        switch flavor {
        case "issue":
            baseArgs = [
                "issue", "list",
                "--repo", scope.id,
                "--limit", "30",
                "--state", "open",
                "--json", "number,title,url,author,updatedAt"
            ]
        case "pr":
            baseArgs = [
                "pr", "list",
                "--repo", scope.id,
                "--limit", "30",
                "--state", "open",
                "--json", "number,title,url,author,updatedAt,isDraft"
            ]
        default:
            return .error("Unknown flavor: \(flavor)")
        }

        do {
            let result = try await ShellRunner.run(
                executable: gh,
                args: baseArgs,
                cwd: projectPath
            )

            if result.exitCode != 0 {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .error(message.isEmpty ? "gh exited \(result.exitCode)" : message)
            }

            return .items(decodeRows(result.stdout, flavor: flavor))
        } catch ShellError.executableNotFound {
            return .error("gh: command not found")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Internal so RigTests can pin a `gh issue list --json ...` fixture and
    /// detect schema drift loudly. The fetch path itself shells out to `gh`,
    /// which isn't reliable in CI.
    func decodeRows(_ json: String, flavor: ReferenceFlavor.ID) -> [ReferenceItem] {
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        // RelativeDateTimeFormatter isn't Sendable; create per call so we don't
        // reach for `nonisolated(unsafe)` over a shared instance.
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated

        guard let rows = try? decoder.decode([GHRow].self, from: data) else {
            return []
        }

        return rows.map { row in
            let updated = isoFractional.date(from: row.updatedAt)
                ?? isoPlain.date(from: row.updatedAt)
            let when = updated.map { relative.localizedString(for: $0, relativeTo: .now) }
            let parts: [String?] = [
                "#\(row.number)",
                row.author?.login.map { "@\($0)" },
                when
            ]
            let prefix: String = (flavor == "pr") ? "pr" : "issue"
            return ReferenceItem(
                id: "\(prefix)-\(row.number)",
                title: row.title,
                subtitle: parts.compactMap { $0 }.joined(separator: " · "),
                url: row.url
            )
        }
    }

    private func decodeNameWithOwner(_ json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        struct Wrap: Decodable { let nameWithOwner: String }
        return (try? JSONDecoder().decode(Wrap.self, from: data))?.nameWithOwner
    }

    /// Parses common ways users name a GitHub repo. Internal so RigTests can
    /// poke at it directly without spawning `gh`.
    static func parseRepoIdentifier(_ input: String) -> (owner: String, name: String)? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        // Strip URL scheme: https://github.com/foo/bar -> github.com/foo/bar
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
        }
        // Strip ssh prefix: git@github.com:foo/bar.git -> foo/bar.git
        if s.hasPrefix("git@"), let colon = s.firstIndex(of: ":") {
            s = String(s[s.index(after: colon)...])
        }
        // Strip the host: github.com/foo/bar -> foo/bar
        if let host = s.range(of: "github.com/") {
            s = String(s[host.upperBound...])
        }
        // Strip the trailing query/fragment if pasted from a long URL.
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }

        // Don't omit empty parts: that way leading-slash garbage like
        // "/owner/name" produces an empty first element and gets rejected
        // below, instead of silently parsing.
        let parts = s.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }

        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        if owner.isEmpty || name.isEmpty { return nil }
        if owner.contains(" ") || name.contains(" ") { return nil }
        return (owner, name)
    }
}

private struct GHRow: Decodable {
    let number: Int
    let title: String
    let url: URL
    let updatedAt: String  // raw — gh emits ISO 8601 with Z suffix
    let author: GHAuthor?
}

private struct GHAuthor: Decodable {
    // gh sometimes emits `"author": {}` (deleted user); login is optional.
    let login: String?
}
