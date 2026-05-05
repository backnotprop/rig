import Foundation

/// What flag UI a given harness exposes in Settings, and how each flag turns into
/// a CLI argument when the harness is launched. Hardcoded per harness id; not
/// persisted (it's not user data).
struct HarnessFlagSchema: Equatable {
    var toggles: [HarnessToggleSpec] = []
    var pickers: [HarnessPickerSpec] = []

    static let empty = HarnessFlagSchema()

    var isEmpty: Bool { toggles.isEmpty && pickers.isEmpty }
}

/// How the harness's CLI accepts an initial prompt.
///   - `.positional`: `command 'prompt'` — pi, codex, claude.
///   - `.flag("name")`: `command --name 'prompt'` — opencode uses `--prompt`.
///   - `.repl`: command runs first, prompt is typed into the REPL as a second
///     line of initial input. For interactive CLIs that don't accept a prompt
///     on the command line at all.
enum PromptStyle: Equatable, Codable {
    case positional
    case flag(String)
    case repl

    // Codable: "positional", "repl", or {"flag": "name"}
    private enum CodingKeys: String, CodingKey { case flag }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) {
            switch s {
            case "positional": self = .positional
            case "repl": self = .repl
            default: self = .positional
            }
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .flag)
            self = .flag(name)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .positional:
            var c = encoder.singleValueContainer()
            try c.encode("positional")
        case .repl:
            var c = encoder.singleValueContainer()
            try c.encode("repl")
        case .flag(let name):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .flag)
        }
    }
}

struct HarnessToggleSpec: Identifiable, Equatable {
    let key: String
    let label: String
    let cliFlag: String
    var id: String { key }
}

struct HarnessPickerSpec: Identifiable, Equatable {
    let key: String
    let label: String
    let cliFlag: String
    let defaultValue: String
    let options: [HarnessPickerOption]
    var id: String { key }
}

struct HarnessPickerOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }
}

enum HarnessSchemas {
    static func schema(for harnessID: String) -> HarnessFlagSchema {
        switch harnessID {
        case "pi":
            return .empty
        case "codex":
            return HarnessFlagSchema(
                toggles: [
                    HarnessToggleSpec(key: "yolo", label: "YOLO mode", cliFlag: "--yolo")
                ]
            )
        case "opencode":
            return HarnessFlagSchema(
                toggles: [
                    HarnessToggleSpec(key: "yolo", label: "YOLO mode", cliFlag: "--yolo")
                ]
            )
        case "claude-code":
            return HarnessFlagSchema(
                toggles: [
                    HarnessToggleSpec(
                        key: "dangerously-skip-permissions",
                        label: "YOLO mode",
                        cliFlag: "--dangerously-skip-permissions"
                    )
                ],
                pickers: [
                    HarnessPickerSpec(
                        key: "permission-mode",
                        label: "Permission mode",
                        cliFlag: "--permission-mode",
                        defaultValue: "default",
                        options: [
                            HarnessPickerOption(value: "default", label: "Default"),
                            HarnessPickerOption(value: "acceptEdits", label: "Accept edits"),
                            HarnessPickerOption(value: "plan", label: "Plan only"),
                            HarnessPickerOption(value: "auto", label: "Auto"),
                            HarnessPickerOption(value: "dontAsk", label: "Don't ask"),
                            HarnessPickerOption(value: "bypassPermissions", label: "Bypass permissions")
                        ]
                    )
                ]
            )
        default:
            return .empty
        }
    }

    /// Composes the actual command-line that gets piped into the new Ghostty session.
    /// Format: `<harness.command> <toggle-cli-flag>... <picker-cli-flag> <value>... [prompt]`.
    /// Picker values matching the schema's `defaultValue` are omitted (no point in
    /// emitting `--permission-mode default` when that's the CLI's default behavior).
    /// When `prompt` is non-empty, it's single-quote shell-escaped and appended at
    /// the end — positional for most harnesses, `--prompt '<value>'` for opencode.
    /// Composes the text that gets typed into the new Ghostty session as
    /// initial input.
    ///
    /// For `.positional` and `.flag` prompt styles, the result is a single
    /// command line: `command [flags] ['prompt']`.
    ///
    /// For `.repl`, the command and prompt are separate lines so the shell
    /// runs the command first (starting the REPL), then the prompt is typed
    /// into the running process as its first input.
    static func composedCommand(for harness: Harness, prompt: String = "") -> String {
        let schema = schema(for: harness.id)
        var parts: [String] = []
        let trimmed = harness.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }

        for toggle in schema.toggles {
            if case .bool(true) = harness.flags[toggle.key] {
                parts.append(toggle.cliFlag)
            }
        }

        for picker in schema.pickers {
            if case .string(let value) = harness.flags[picker.key],
                value != picker.defaultValue
            {
                parts.append(picker.cliFlag)
                parts.append(value)
            }
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            let quoted = shellSingleQuote(trimmedPrompt)
            switch harness.promptStyle {
            case .positional:
                parts.append(quoted)
            case .flag(let name):
                parts.append("--\(name)")
                parts.append(quoted)
            case .repl:
                // Command is on one line, prompt on the next. The newline
                // causes the shell to execute the command; then the prompt
                // text is typed into the now-running REPL.
                return parts.joined(separator: " ") + "\n" + trimmedPrompt
            }
        }

        return parts.joined(separator: " ")
    }

    /// Wraps `value` in single quotes for safe shell pasting. Single-quoting disables
    /// every form of expansion — variables, backticks, escapes — so the only character
    /// we need to handle is `'` itself, which we close-quote, escape, and re-open.
    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
