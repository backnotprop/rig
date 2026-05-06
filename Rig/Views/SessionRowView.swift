import SwiftUI

struct SessionRowView: View {
    let session: GhosttySession
    let isSelected: Bool
    let servers: [DetectedServer]
    let onOpenServer: (DetectedServer) -> Void
    let onOpenServerInSplit: (DetectedServer) -> Void
    let onOpenServerInNativeSplit: (DetectedServer) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionLabel
            serverList
        }
    }

    private var sessionLabel: some View {
        HStack(spacing: 9) {
            Text(session.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(session.isBackgrounded ? .secondary : .primary)
                .italic(session.isBackgrounded)

            if session.isBackgrounded {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help("Backgrounded — click to bring forward")
            }

            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

            if isSelected {
                shape.fill(Color.white.opacity(0.12))
            } else if isHovered {
                shape.fill(Color.white.opacity(0.05))
            }
        }
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.16), value: isSelected)
        .animation(.snappy(duration: 0.16), value: isHovered)
        .accessibilityLabel(session.label)
    }

    @ViewBuilder
    private var serverList: some View {
        if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(servers) { server in
                    HStack(spacing: 6) {
                        Button {
                            onOpenServer(server)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "network")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text(server.displayLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(server.url.absoluteString)")

                        Button {
                            onOpenServerInSplit(server)
                        } label: {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open beside Ghostty")

                        // TODO(native-split): Re-enable after the fullscreen
                        // Split View prototype is reliable. The best version
                        // drove macOS from Ghostty first (Full Screen Tile >
                        // Left of Screen), then clicked the browser candidate
                        // on the right. It still has flaky picker/teardown
                        // behavior, so keep only the stable desktop split
                        // button visible for now.
                        /*
                        Button {
                            onOpenServerInNativeSplit(server)
                        } label: {
                            Image(systemName: "rectangle.split.2x1.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in native Split View")
                        */
                    }
                }
            }
            .padding(.leading, 26)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }
}

#Preview {
    VStack(spacing: 4) {
        SessionRowView(
            session: GhosttySession(
                id: UUID(),
                label: "Pi — scratch",
                ghosttyWindowId: "w",
                ghosttyTabId: "t",
                ghosttyTerminalId: "term"
            ),
            isSelected: true,
            servers: [
                DetectedServer(id: "test|3000", port: 3000, processName: "node"),
                DetectedServer(id: "test|5173", port: 5173, processName: "vite")
            ],
            onOpenServer: { _ in },
            onOpenServerInSplit: { _ in },
            onOpenServerInNativeSplit: { _ in }
        )
        SessionRowView(
            session: GhosttySession(
                id: UUID(),
                label: "Claude Code — rig",
                ghosttyWindowId: "w2",
                ghosttyTabId: "t2",
                ghosttyTerminalId: "term2"
            ),
            isSelected: false,
            servers: [],
            onOpenServer: { _ in },
            onOpenServerInSplit: { _ in },
            onOpenServerInNativeSplit: { _ in }
        )
    }
    .padding()
    .frame(width: 240)
    .background(Color.gray.opacity(0.2))
}
