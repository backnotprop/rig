import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var settings: HarnessSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AGENTS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)

                VStack(spacing: 0) {
                    ForEach(Array($settings.harnesses.enumerated()), id: \.element.id) { index, $harness in
                        HarnessRow(harness: $harness)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        if index < settings.harnesses.count - 1 {
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

                Text("Each agent runs its startup command in a new Ghostty session. Disabled agents are hidden from the launcher row.")
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
    @Binding var harness: LauncherHarness

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LauncherIconView(harness: harness, size: 38)
                .opacity(harness.enabled ? 1.0 : 0.30)
                .grayscale(harness.enabled ? 0.0 : 0.6)

            VStack(alignment: .leading, spacing: 6) {
                Text(harness.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(harness.enabled ? .primary : .tertiary)

                TextField("Startup command", text: $harness.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .disabled(!harness.enabled)
                    .opacity(harness.enabled ? 1.0 : 0.35)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $harness.enabled.animation(.easeInOut(duration: 0.18))) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .fixedSize()
        }
    }
}
