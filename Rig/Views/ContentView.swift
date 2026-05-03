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
    @EnvironmentObject private var projects: ProjectsViewModel
    @FocusState private var isListFocused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    LauncherRowView(
                        harnesses: LauncherHarness.defaults,
                        isDisabled: viewModel.isCreatingSession,
                        onTap: { _ in
                            let cwd = projects.selectedProject?.path
                            Task { await viewModel.createSession(workingDirectory: cwd) }
                        }
                    )

                    ProjectSelectorView()
                        .padding(.leading, 4)
                }
                .padding(.top, 28)

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
        .frame(
            minWidth: 176,
            idealWidth: 240,
            maxWidth: .infinity,
            minHeight: 240,
            idealHeight: 360,
            maxHeight: .infinity
        )
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onAppear {
            isListFocused = true
        }
        .onMoveCommand { direction in
            viewModel.moveSelection(direction)
        }
        .onDeleteCommand {
            viewModel.removeSelected()
        }
        .onKeyPress(.return) {
            Task { await viewModel.focusSelected() }
            return .handled
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

    private var emptyState: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                Image("Truck")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.tertiary)
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(viewModel.sessions) { session in
                    Button {
                        viewModel.requestFocus(session)
                    } label: {
                        SessionRowView(
                            session: session,
                            isSelected: viewModel.selectedSessionID == session.id,
                            glassNamespace: glassNamespace
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove") {
                            viewModel.remove(session)
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionListViewModel(
            controller: PreviewGhosttyController(),
            store: SessionStore(fileURL: URL(fileURLWithPath: "/tmp/rig-preview.json"))
        ))
        .environmentObject(ProjectsViewModel(
            storeURL: URL(fileURLWithPath: "/tmp/rig-preview-projects.json")
        ))
}

private struct PreviewGhosttyController: GhosttyControlling {
    func createWindow(workingDirectory: String) async throws -> CreatedGhosttySurface {
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
