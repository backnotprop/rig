import SwiftUI

struct SessionRowView: View {
    let session: GhosttySession
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
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
        // Why plain tinted fills (not .glassEffect): the panel background is already
        // an NSVisualEffectView. Stacking SwiftUI .glassEffect on top produces an
        // intensely over-blurred result ("glass on glass") that Apple's docs explicitly
        // warn against.
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

#Preview {
    VStack(spacing: 4) {
        SessionRowView(
            session: GhosttySession(
                id: UUID(),
                label: "Session 1",
                ghosttyWindowId: "w",
                ghosttyTabId: "t",
                ghosttyTerminalId: "term"
            ),
            isSelected: true
        )
        SessionRowView(
            session: GhosttySession(
                id: UUID(),
                label: "Session 2",
                ghosttyWindowId: "w2",
                ghosttyTabId: "t2",
                ghosttyTerminalId: "term2"
            ),
            isSelected: false
        )
    }
    .padding()
    .frame(width: 240)
    .background(Color.gray.opacity(0.2))
}
