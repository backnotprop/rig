import Foundation

/// Creates git worktrees for Rig sessions. The worktree path is determined
/// by the user's `worktreeLocation` preference (tmp or parent directory).
enum WorktreeManager {
    struct WorktreeResult {
        let path: String
        let branch: String
    }

    enum WorktreeError: LocalizedError {
        case noProject
        case notAGitRepo
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProject: "No project selected"
            case .notAGitRepo: "Project is not a git repository"
            case .creationFailed(let msg): msg
            }
        }
    }

    /// Creates a git worktree and returns the path to it.
    /// Matches the `wt` alias convention: branch name keeps slashes
    /// (`fix/something`), directory name replaces them with dashes
    /// (`fix-something`), and the worktree is based off `main`.
    static func create(
        name: String,
        projectPath: String,
        location: WorktreeLocation
    ) async throws -> WorktreeResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorktreeError.creationFailed("Worktree name is empty")
        }

        let gitDir = (projectPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            throw WorktreeError.notAGitRepo
        }

        // Branch keeps the original name (slashes preserved: fix/something).
        // Directory flattens slashes to dashes (fix-something), matching `wt` alias.
        let branchName = trimmedName.replacingOccurrences(of: " ", with: "-")
        let dirName = branchName.replacingOccurrences(of: "/", with: "-")

        let worktreePath: String
        switch location {
        case .tmp:
            let projectName = (projectPath as NSString).lastPathComponent
            worktreePath = "/tmp/rig-worktrees/\(projectName)/\(dirName)"
        case .parentDirectory:
            let parent = (projectPath as NSString).deletingLastPathComponent
            worktreePath = (parent as NSString).appendingPathComponent(dirName)
        }

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: (worktreePath as NSString).deletingLastPathComponent),
            withIntermediateDirectories: true
        )

        guard let git = ShellRunner.resolve("git") else {
            throw WorktreeError.creationFailed("git not found")
        }

        // git worktree add -b <branch> <path> main
        let result = try await ShellRunner.run(
            executable: git,
            args: ["worktree", "add", "-b", branchName, worktreePath, "main"],
            cwd: projectPath
        )

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.creationFailed(stderr.isEmpty ? "git worktree add failed" : stderr)
        }

        return WorktreeResult(path: worktreePath, branch: branchName)
    }
}
