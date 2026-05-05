import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default click action")
                            .font(.headline)

                        Picker("", selection: $store.config.preferences.defaultLaunchMode) {
                            ForEach(LaunchMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text("The other action runs on right-click or two-finger tap, so both are always reachable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $store.config.preferences.instantSpaceSwitching) {
                            Text("Instant Space switching")
                                .font(.headline)
                        }
                        .toggleStyle(.switch)

                        Text("When focusing a session on a different Space, switch instantly instead of the default macOS slide animation. Requires Accessibility permission.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}
