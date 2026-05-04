import SwiftUI

/// In-drawer panel that lists items from a `ReferenceProvider` (issues, PRs,
/// future: Linear tickets, etc.) and inserts the URL of the chosen item into
/// the prompt textfield.
///
/// Layout (top to bottom):
///   [scope row]   ← only when provider.scopeKind != nil
///   [flavor segmented picker]   [↻]
///   [loading | message | list]
struct ReferencesPanel: View {
    let provider: any ReferenceProvider
    let projectPath: String?
    /// The full item is handed up so the drawer can build a typed inline chip
    /// (with provider id, kind, etc.), not just a URL string.
    let onPick: (ReferenceItem) -> Void

    @EnvironmentObject private var store: ConfigStore

    @State private var selectedFlavor: ReferenceFlavor.ID
    @State private var detectedScope: ReferenceScope?
    @State private var selectedScope: ReferenceScope?
    @State private var resultsByKey: [String: ProviderResult] = [:]
    @State private var loadingKeys: Set<String> = []
    @State private var fetchTask: Task<Void, Never>?

    // Inline "Add scope" input state
    @State private var isAddingScope = false
    @State private var customScopeInput = ""
    @State private var customScopeError: String?
    @State private var isResolvingCustomScope = false
    @FocusState private var customScopeFieldFocused: Bool

    init(
        provider: any ReferenceProvider,
        projectPath: String?,
        onPick: @escaping (ReferenceItem) -> Void
    ) {
        self.provider = provider
        self.projectPath = projectPath
        self.onPick = onPick
        self._selectedFlavor = State(initialValue: provider.flavors.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider.scopeKind != nil {
                scopeRow
            }
            flavorRow
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear {
            Task { await detectAndAutoSelect() }
        }
        .onChange(of: selectedFlavor) { _, _ in fetchIfNeeded(force: false) }
        .onChange(of: selectedScope) { _, _ in fetchIfNeeded(force: false) }
        .onChange(of: projectPath) { _, _ in
            resultsByKey.removeAll()
            selectedScope = nil
            detectedScope = nil
            Task { await detectAndAutoSelect() }
        }
    }

    // MARK: - Scope row

    @ViewBuilder
    private var scopeRow: some View {
        if isAddingScope {
            addScopeInput
        } else {
            scopeMenu
        }
    }

    private var scopeMenu: some View {
        Menu {
            if let detected = detectedScope {
                Button {
                    selectScope(detected, recordRecent: false)
                } label: {
                    if detected.id == selectedScope?.id {
                        Label("Detected: \(detected.displayName)", systemImage: "checkmark")
                    } else {
                        Text("Detected: \(detected.displayName)")
                    }
                }
            }

            let recents = store.recentScopes(providerID: provider.id)
                .filter { $0.id != detectedScope?.id }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents) { scope in
                        Button {
                            selectScope(scope, recordRecent: true)
                        } label: {
                            if scope.id == selectedScope?.id {
                                Label(scope.displayName, systemImage: "checkmark")
                            } else {
                                Text(scope.displayName)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                openAddScope()
            } label: {
                Label("Add \((provider.scopeKind ?? "scope").lowercased())…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Text(scopeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var scopeLabel: String {
        if let s = selectedScope { return s.displayName }
        return "Select a \((provider.scopeKind ?? "scope").lowercased())"
    }

    private var addScopeInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("owner/name or URL", text: $customScopeInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($customScopeFieldFocused)
                    .onSubmit { submitCustomScope() }
                    .disabled(isResolvingCustomScope)

                if isResolvingCustomScope {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        submitCustomScope()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .help("Add")
                    .disabled(customScopeInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        cancelAddScope()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
            }

            if let err = customScopeError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(2)
            }
        }
    }

    private func openAddScope() {
        isAddingScope = true
        customScopeInput = ""
        customScopeError = nil
        // Slight delay so the field is in the tree before focus.
        DispatchQueue.main.async { customScopeFieldFocused = true }
    }

    private func cancelAddScope() {
        isAddingScope = false
        customScopeInput = ""
        customScopeError = nil
    }

    private func submitCustomScope() {
        let input = customScopeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        customScopeError = nil
        isResolvingCustomScope = true

        Task {
            let resolution = await provider.resolveScope(input)
            isResolvingCustomScope = false
            switch resolution {
            case .ok(let scope):
                selectScope(scope, recordRecent: true)
                isAddingScope = false
                customScopeInput = ""
            case .error(let message):
                customScopeError = message
            }
        }
    }

    // MARK: - Flavor row

    private var flavorRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedFlavor) {
                ForEach(provider.flavors) { flavor in
                    Text(flavor.label).tag(flavor.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(provider.scopeKind != nil && selectedScope == nil)

            Button {
                fetchIfNeeded(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(loadingKeys.contains(currentKey) || (provider.scopeKind != nil && selectedScope == nil))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if provider.scopeKind != nil && selectedScope == nil {
            stateMessage(
                "Pick a \((provider.scopeKind ?? "scope").lowercased()) to see items.",
                monospaced: false
            )
        } else if loadingKeys.contains(currentKey) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        } else {
            switch resultsByKey[currentKey] {
            case .items(let items) where items.isEmpty:
                emptyState
            case .items(let items):
                list(items)
            case .noContext(let message):
                stateMessage(message, monospaced: false)
            case .error(let message):
                stateMessage(message, monospaced: true)
            case nil:
                EmptyView()
            }
        }
    }

    private func list(_ items: [ReferenceItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        onPick(item)
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func row(_ item: ReferenceItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        Text("No open \(selectedFlavor == "pr" ? "pull requests" : "items").")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    private func stateMessage(_ message: String, monospaced: Bool) -> some View {
        Text(message)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: - Fetch coordination

    private var currentKey: String {
        let scopeKey = selectedScope?.id ?? "_"
        return "\(scopeKey)|\(selectedFlavor)"
    }

    private func selectScope(_ scope: ReferenceScope, recordRecent: Bool) {
        selectedScope = scope
        if recordRecent {
            store.recordRecentScope(providerID: provider.id, scope: scope)
        }
    }

    private func detectAndAutoSelect() async {
        let detected = await provider.detectedScope(projectPath: projectPath)
        detectedScope = detected
        // Only auto-select detected if the user hasn't already picked one.
        if selectedScope == nil, let detected {
            selectedScope = detected
        }
    }

    private func fetchIfNeeded(force: Bool) {
        // Don't try to fetch on a scoped provider until we have a scope.
        if provider.scopeKind != nil && selectedScope == nil { return }

        let key = currentKey
        if !force, resultsByKey[key] != nil { return }

        fetchTask?.cancel()
        loadingKeys.insert(key)

        let scope = selectedScope
        let flavor = selectedFlavor
        let path = projectPath

        fetchTask = Task { [provider] in
            let result = await provider.fetch(
                flavor: flavor,
                scope: scope,
                projectPath: path
            )
            if Task.isCancelled { return }
            resultsByKey[key] = result
            loadingKeys.remove(key)
        }
    }
}
