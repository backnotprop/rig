import AppKit
import SwiftUI

// Why NSVisualEffectView (not SwiftUI .glassEffect): on macOS 26 (Tahoe), SwiftUI's
// .glassEffect uses NSGlassEffectView, which caches its sampled behind-window content
// and doesn't reliably invalidate when other apps' windows move/close. Result: ghost
// shadows. NSVisualEffectView with .behindWindow blendingMode is the canonical AppKit
// primitive that gets compositor-driven invalidation.
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var appDelegate: AppDelegate
    @FocusState private var isListFocused: Bool
    @State private var expandedHarnessID: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mainContent
            settingsButton
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onAppear {
            isListFocused = true
            viewModel.instantSpaceSwitching = store.config.preferences.instantSpaceSwitching
        }
        .onChange(of: store.config.preferences.instantSpaceSwitching) { _, newValue in
            viewModel.instantSpaceSwitching = newValue
        }
        .onMoveCommand { direction in
            viewModel.moveSelection(direction)
        }
        .onDeleteCommand {
            viewModel.removeSelected()
        }
        .onKeyPress(.return) {
            // When the drawer is up, Return belongs to the prompt composer
            // (newline insertion). Only claim it for "focus selected session"
            // on the bare main surface.
            if expandedHarnessID != nil { return .ignored }
            Task { await viewModel.focusSelected() }
            return .handled
        }
        .onKeyPress(.escape) {
            if expandedHarnessID != nil {
                closeDrawer()
                return .handled
            }
            return .ignored
        }
        .alert(
            "Rig hit a snag",
            isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button("OK") { viewModel.dismissError() }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    private func launch(_ harness: Harness, bringToFront: Bool, prompt: String = "") {
        let cwd = store.selectedProject?.path
        let projectID = store.selectedProject?.id
        let composed = HarnessSchemas.composedCommand(for: harness, prompt: prompt)
        Task {
            await viewModel.createSession(
                workingDirectory: cwd,
                command: composed,
                harnessID: harness.id,
                projectID: projectID,
                labelPrefix: harness.label,
                bringToFront: bringToFront
            )
        }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            expandedHarnessID = nil
        }
    }

    private func toggleDrawer(for harness: Harness) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            expandedHarnessID = (expandedHarnessID == harness.id) ? nil : harness.id
        }
    }

    /// Routes a click to either an immediate launch or the prompt drawer based
    /// on the user's `defaultLaunchMode` preference. Primary click runs the
    /// default action; secondary (right-click / two-finger) runs the other one.
    private func handleClick(_ harness: Harness, isPrimary: Bool) {
        let useLaunch = (store.config.preferences.defaultLaunchMode == .launch) == isPrimary
        if useLaunch {
            launch(harness, bringToFront: true)
        } else {
            toggleDrawer(for: harness)
        }
    }

    private var settingsButton: some View {
        Button {
            appDelegate.presentSettingsWindow()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(0.55)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
        .padding(.top, 12)
        .padding(.trailing, 14)
    }

    private var mainContent: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                LauncherRowView(
                    harnesses: store.enabledHarnesses,
                    isDisabled: viewModel.isCreatingSession,
                    onTap: { harness in handleClick(harness, isPrimary: true) },
                    onSecondaryTap: { harness in handleClick(harness, isPrimary: false) }
                )

                ProjectSelectorView()
                    .padding(.leading, 4)
            }
            .padding(.top, 28)

            if let id = expandedHarnessID,
                let harness = store.config.harnesses.first(where: { $0.id == id })
            {
                LauncherDrawer(
                    harness: harness,
                    onRun: { prompt in
                        launch(harness, bringToFront: true, prompt: prompt)
                        closeDrawer()
                    },
                    onBackground: { prompt in
                        launch(harness, bringToFront: false, prompt: prompt)
                        closeDrawer()
                    },
                    onClose: closeDrawer
                )
                .padding(.horizontal, 4)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }

            if viewModel.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .padding(8)
        .frame(
            minWidth: 176,
            idealWidth: 240,
            maxWidth: .infinity,
            minHeight: 240,
            idealHeight: 360,
            maxHeight: .infinity
        )
        .background(
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow
            )
            .overlay(Color.white.opacity(0.04))
        )
    }

    private var emptyState: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if let projectID = store.config.preferences.selectedProjectID {
                    let filtered = viewModel.sessions.filter { $0.projectID == projectID }
                    ForEach(filtered) { session in
                        sessionRow(session)
                    }
                } else {
                    ForEach(groupedSessions) { group in
                        Text(group.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                            .padding(.top, 6)
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func sessionRow(_ session: GhosttySession) -> some View {
        Button {
            viewModel.requestFocus(session)
        } label: {
            SessionRowView(
                session: session,
                isSelected: viewModel.selectedSessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove") {
                viewModel.remove(session)
            }
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    private var groupedSessions: [SessionGroup] {
        var groups: [SessionGroup] = []
        for project in store.config.projects {
            let sessions = viewModel.sessions.filter { $0.projectID == project.id }
            if !sessions.isEmpty {
                groups.append(
                    SessionGroup(
                        id: project.id.uuidString,
                        title: project.displayName,
                        sessions: sessions
                    )
                )
            }
        }
        let orphans = viewModel.sessions.filter { $0.projectID == nil }
        if !orphans.isEmpty {
            groups.append(
                SessionGroup(id: "no-project", title: "No project", sessions: orphans)
            )
        }
        return groups
    }
}

private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [GhosttySession]
}

#Preview {
    ContentView()
        .environmentObject(SessionListViewModel(controller: PreviewGhosttyController()))
        .environmentObject(ConfigStore(storeURL: URL(fileURLWithPath: "/tmp/rig-preview-config.json")))
        .environmentObject(AppDelegate())
}

private struct PreviewGhosttyController: GhosttyControlling {
    func createWindow(
        workingDirectory: String,
        initialInput: String?,
        bringToFront: Bool
    ) async throws -> CreatedGhosttySurface {
        CreatedGhosttySurface(
            windowId: "preview-window",
            tabId: "preview-tab",
            terminalId: "preview-terminal",
            workingDirectory: workingDirectory
        )
    }

    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface {
        CreatedGhosttySurface(
            windowId: windowId,
            tabId: tabId,
            terminalId: terminalId,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}
