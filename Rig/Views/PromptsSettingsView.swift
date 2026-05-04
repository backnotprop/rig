import SwiftUI

struct PromptsSettingsView: View {
    @EnvironmentObject private var store: ConfigStore
    @FocusState private var focusedMarkerID: SavedPrompt.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            if store.config.prompts.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $store.config.preferences.promptSortOrder) {
                ForEach(PromptSortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                let id = store.addPrompt()
                // Drop into custom so the new (empty-marker, empty-body) prompt
                // is reachable at a stable spot rather than being sorted to
                // the back of the .lastUsed/.created views.
                store.config.preferences.promptSortOrder = .custom
                focusedMarkerID = id
            } label: {
                Label("New", systemImage: "plus")
            }
            .controlSize(.regular)
        }
    }

    private var list: some View {
        let prompts = store.displayPrompts
        return List {
            ForEach(prompts) { prompt in
                PromptRow(
                    prompt: bindingForPrompt(prompt),
                    onDelete: { store.removePrompt(id: prompt.id) }
                )
                .focused($focusedMarkerID, equals: prompt.id)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                store.movePromptsInVisibleOrder(
                    currentlyVisible: prompts,
                    fromOffsets: source,
                    toOffset: destination
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No saved prompts yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Tap + to create one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bindingForPrompt(_ prompt: SavedPrompt) -> Binding<SavedPrompt> {
        Binding(
            get: {
                store.config.prompts.first { $0.id == prompt.id } ?? prompt
            },
            set: { newValue in
                guard let idx = store.config.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
                store.config.prompts[idx] = newValue
            }
        )
    }
}

private struct PromptRow: View {
    @Binding var prompt: SavedPrompt
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ChipPreview(marker: prompt.marker, tint: prompt.tint.color)

            TextField("•", text: markerBinding)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 60)

            TextField("Prompt body", text: $prompt.body, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            ColorPicker("", selection: tintBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // Capping marker length on write keeps the data model honest regardless of
    // what the user pastes in (one emoji is one grapheme cluster, "AB" is two,
    // "Hello" gets truncated to "He").
    private var markerBinding: Binding<String> {
        Binding(
            get: { prompt.marker },
            set: { prompt.marker = $0.truncatedToGraphemes(2) }
        )
    }

    private var tintBinding: Binding<Color> {
        Binding(
            get: { prompt.tint.color },
            set: { prompt.tint = HexColor(color: $0) }
        )
    }
}

private struct ChipPreview: View {
    let marker: String
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 30, height: 30)
            .overlay(
                Text(marker)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
            )
            .overlay(
                Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1.0)
            )
    }
}
