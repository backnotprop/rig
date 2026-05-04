import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array($store.config.harnesses.enumerated()), id: \.element.id) {
                        index, $harness in
                        HarnessRow(harness: $harness)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        if index < store.config.harnesses.count - 1 {
                            Divider()
                                .padding(.leading, 70)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

                Text(
                    "Each agent runs its startup command in a new Ghostty session. Disabled agents are hidden from the launcher row."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HarnessRow: View {
    @Binding var harness: Harness

    private var schema: HarnessFlagSchema { HarnessSchemas.schema(for: harness.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LauncherIconView(harness: harness, size: 38)
                .padding(.top, 2)
                .opacity(harness.enabled ? 1.0 : 0.30)
                .grayscale(harness.enabled ? 0.0 : 0.6)

            VStack(alignment: .leading, spacing: 8) {
                Text(harness.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(harness.enabled ? .primary : .tertiary)

                TextField("Startup command", text: $harness.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .disabled(!harness.enabled)
                    .opacity(harness.enabled ? 1.0 : 0.35)

                if !schema.isEmpty {
                    flagSection
                        .opacity(harness.enabled ? 1.0 : 0.45)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $harness.enabled.animation(.easeInOut(duration: 0.18))) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var flagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(schema.toggles) { toggle in
                Toggle(isOn: boolBinding(for: toggle.key)) {
                    Text(toggle.label).font(.callout)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!harness.enabled)
            }

            ForEach(schema.pickers) { picker in
                LabeledContent {
                    Picker("", selection: stringBinding(for: picker.key, default: picker.defaultValue)) {
                        ForEach(picker.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!harness.enabled)
                } label: {
                    Text(picker.label)
                        .font(.callout)
                }
            }

            if let preview = composedCommandPreview {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// The full command Rig will run, shown faded under the flags so the user can see
    /// the effect of their toggles without us having to reach into the editable
    /// command field. Returns `nil` when no flag is changing the user's input — keeps
    /// the row uncluttered for harnesses with no active flags.
    private var composedCommandPreview: String? {
        let composed = HarnessSchemas.composedCommand(for: harness)
        let user = harness.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return composed == user ? nil : composed
    }

    // Drop the key entirely when the value is the "off" / default state — keeps
    // config.json from accumulating no-op entries like `"yolo": false`.
    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let b) = harness.flags[key] { return b }
                return false
            },
            set: { newValue in
                if newValue {
                    harness.flags[key] = .bool(true)
                } else {
                    harness.flags.removeValue(forKey: key)
                }
            }
        )
    }

    private func stringBinding(for key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: {
                if case .string(let s) = harness.flags[key] { return s }
                return defaultValue
            },
            set: { newValue in
                if newValue == defaultValue {
                    harness.flags.removeValue(forKey: key)
                } else {
                    harness.flags[key] = .string(newValue)
                }
            }
        )
    }
}
