import Foundation

/// What flag UI a given harness exposes in Settings, and how each flag turns into
/// a CLI argument when the harness is launched. Hardcoded per harness id; not
/// persisted (it's not user data).
struct HarnessFlagSchema: Equatable {
    var toggles: [HarnessToggleSpec] = []
    var pickers: [HarnessPickerSpec] = []
    var promptStyle: PromptStyle = .positional

    static let empty = HarnessFlagSchema()

    var isEmpty: Bool { toggles.isEmpty && pickers.isEmpty }
}

/// How the harness's CLI accepts an initial prompt. Always appended to the end of
/// the composed command, after toggles and pickers.
enum PromptStyle: Equatable {
    /// `<command> 'prompt'` — pi, codex, claude.
    case positional
    /// `<command> --<name> 'prompt'` — opencode uses `--prompt`.
    case flag(String)
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
                ],
                promptStyle: .flag("prompt")
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
                // Space-separated rather than `--flag=value`. Claude's CLI requires
                // the space form (`--permission-mode plan`). The space form is also
                // accepted universally by POSIX-style CLIs; the `=` form isn't.
                parts.append(picker.cliFlag)
                parts.append(value)
            }
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            let quoted = shellSingleQuote(trimmedPrompt)
            switch schema.promptStyle {
            case .positional:
                parts.append(quoted)
            case .flag(let name):
                parts.append("--\(name)")
                parts.append(quoted)
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
