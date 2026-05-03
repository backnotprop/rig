import SwiftUI

struct SessionRowView: View {
    let session: GhosttySession
    let isSelected: Bool
    let glassNamespace: Namespace.ID
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Text(session.label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(.primary)

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
}

private struct SessionRowPreview: View {
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(spacing: 4) {
                SessionRowView(
                    session: GhosttySession(
                        id: UUID(),
                        label: "Session 1",
                        ghosttyWindowId: "w",
                        ghosttyTabId: "t",
                        ghosttyTerminalId: "term"
                    ),
                    isSelected: true,
                    glassNamespace: glassNamespace
                )
                SessionRowView(
                    session: GhosttySession(
                        id: UUID(),
                        label: "Session 2",
                        ghosttyWindowId: "w2",
                        ghosttyTabId: "t2",
                        ghosttyTerminalId: "term2"
                    ),
                    isSelected: false,
                    glassNamespace: glassNamespace
                )
            }
            .padding()
        }
    }
}

#Preview {
    SessionRowPreview()
}
