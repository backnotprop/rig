import AppKit
import SwiftUI

// MARK: - Right-click capture

/// Adds a transparent NSView overlay that intercepts right-mouse-down (and
/// trackpad two-finger tap, which macOS routes through the same event) without
/// stealing primary clicks. The trick: hitTest returns nil when the secondary
/// button isn't currently pressed, so primary clicks fall through to the
/// underlying SwiftUI view as if we weren't there.
extension View {
    func onSecondaryClick(perform action: @escaping () -> Void) -> some View {
        self.overlay(SecondaryClickCatcher(action: action))
    }
}

private struct SecondaryClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SecondaryClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SecondaryClickNSView)?.action = action
    }
}

private final class SecondaryClickNSView: NSView {
    var action: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        action?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim the click when the secondary mouse button is currently
        // pressed. Bit 1 (mask 0b10) of pressedMouseButtons is the right
        // button. For all other states (no buttons, primary down, hover) we
        // return nil so the underlying SwiftUI Button receives the event.
        if NSEvent.pressedMouseButtons & (1 << 1) != 0 {
            return self
        }
        return nil
    }
}

// MARK: - Drawer

struct LauncherDrawer: View {
    let harness: Harness
    let onRun: (String) -> Void
    let onBackground: (String) -> Void
    let onClose: () -> Void

    @State private var prompt: String = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LauncherIconView(harness: harness, size: 22)
                Text(harness.label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            TextField("Optional prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .focused($isPromptFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                DrawerActionButton(
                    tooltip: "Run",
                    systemImage: "play.fill",
                    action: { onRun(prompt) }
                )
                DrawerActionButton(
                    tooltip: "Run in background",
                    systemImage: "arrow.up.right.and.arrow.down.left",
                    action: { onBackground(prompt) }
                )
            }
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
        .onAppear { isPromptFocused = true }
    }
}

private struct DrawerActionButton: View {
    let tooltip: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
