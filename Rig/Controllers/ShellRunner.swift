import Foundation

struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: Error {
    case executableNotFound(String)
    case launchFailed(String)
}

/// Tiny wrapper around Foundation `Process` for the cases where Rig needs to
/// shell out (currently: `gh` and `git rev-parse` from the references panel).
///
/// Why `Process` and not `swift-subprocess`: the project has zero third-party
/// deps and `Process` covers our handful of call sites in ~40 lines. If shell-
/// outs proliferate, swift-subprocess is the modern upgrade path.
enum ShellRunner {
    /// Resolves an absolute path for `tool`. Tries the inherited `PATH` first,
    /// then falls back to common Homebrew locations — Finder/LaunchServices-
    /// launched apps don't inherit a login shell's PATH, so Homebrew tools
    /// (which is where the user's `gh` lives) need explicit fallback.
    static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for component in path.split(separator: ":") {
                let candidate = "\(component)/\(tool)"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        for candidate in ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"] {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    /// Runs `executable` to completion and returns its captured output. Honors
    /// task cancellation — if the surrounding Task is cancelled, the child
    /// process is terminated.
    static func run(
        executable: String,
        args: [String],
        cwd: String? = nil
    ) async throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.executableNotFound(executable)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellResult, Error>) in
                process.terminationHandler = { proc in
                    let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    cont.resume(returning: ShellResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                }

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: ShellError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
