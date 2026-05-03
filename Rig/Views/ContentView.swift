import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: SessionListViewModel
    @FocusState private var isListFocused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                toolbar

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
            .glassEffect(
                .regular.tint(.white.opacity(0.08)),
                in: Rectangle()
            )
            .glassEffectID("rig-shell", in: glassNamespace)
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

    private var toolbar: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                Task { await viewModel.createSession() }
            } label: {
                Image(systemName: viewModel.isCreatingSession ? "hourglass" : "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .disabled(viewModel.isCreatingSession)
            .help("New Session")
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private var emptyState: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, value: viewModel.isCreatingSession)
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
