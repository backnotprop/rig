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

    @EnvironmentObject private var store: ConfigStore
    @State private var prompt: String = ""
    /// Which auxiliary panel is open beneath the action row, if any.
    /// `"library"` for saved prompts, `provider.id` (e.g. `"github"`) for any
    /// reference provider. Only one panel is open at a time so we don't blow
    /// the drawer's vertical budget.
    @State private var openPanelID: String? = nil
    @FocusState private var isPromptFocused: Bool

    private static let libraryPanelID = "library"

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
                DrawerActionButton(
                    tooltip: store.config.prompts.isEmpty
                        ? "No saved prompts — add some in Settings"
                        : "Saved prompts",
                    systemImage: "quote.bubble",
                    isActive: openPanelID == Self.libraryPanelID,
                    action: { togglePanel(Self.libraryPanelID) }
                )
                .disabled(store.config.prompts.isEmpty)
                .opacity(store.config.prompts.isEmpty ? 0.4 : 1.0)

                ForEach(ReferenceRegistry.providers, id: \.id) { provider in
                    DrawerActionButton(
                        tooltip: provider.displayName,
                        assetName: provider.iconAssetName,
                        isActive: openPanelID == provider.id,
                        action: { togglePanel(provider.id) }
                    )
                }
            }

            if openPanelID == Self.libraryPanelID && !store.config.prompts.isEmpty {
                PromptDockView(prompts: store.displayPrompts) { selected in
                    prompt = selected.body
                    store.recordPromptUse(id: selected.id)
                    isPromptFocused = true
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }

            if let panelID = openPanelID,
                let provider = ReferenceRegistry.providers.first(where: { $0.id == panelID })
            {
                ReferencesPanel(
                    provider: provider,
                    projectPath: store.selectedProject?.path,
                    onPick: { url in appendToPrompt(url) }
                )
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
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

    private func togglePanel(_ id: String) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            openPanelID = (openPanelID == id) ? nil : id
        }
    }

    /// Appends a reference URL to the prompt textfield. Inserts a leading
    /// space if the existing prompt is non-empty and doesn't already end in
    /// whitespace, so multiple consecutive picks read as a list.
    private func appendToPrompt(_ url: String) {
        if prompt.isEmpty {
            prompt = url
        } else if let last = prompt.last, last.isWhitespace {
            prompt += url
        } else {
            prompt += " " + url
        }
    }
}

private struct DrawerActionButton: View {
    enum IconKind {
        case systemImage(String)
        case asset(String)
    }

    let tooltip: String
    let icon: IconKind
    var isActive: Bool = false
    let action: () -> Void

    init(tooltip: String, systemImage: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.tooltip = tooltip
        self.icon = .systemImage(systemImage)
        self.isActive = isActive
        self.action = action
    }

    init(tooltip: String, assetName: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.tooltip = tooltip
        self.icon = .asset(assetName)
        self.isActive = isActive
        self.action = action
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            iconView
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(backgroundOpacity))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isActive)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        case .asset(let name):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: 14, height: 14)
        }
    }

    private var backgroundOpacity: Double {
        if isActive { return 0.18 }
        if isHovered { return 0.12 }
        return 0.06
    }
}

// MARK: - Prompt dock
//
// Same magnification model as the harness row above, but anchored to the LEFT
// edge of the drawer so the chips read as a stash you peek into from the left.
// Items overlap at rest (negative spacing) and spread apart under the cursor.

private struct PromptDockView: View {
    let prompts: [SavedPrompt]
    let onSelect: (SavedPrompt) -> Void

    @State private var hoverX: CGFloat?

    private let baseSize: CGFloat = 22
    private let maxSize: CGFloat = 34
    private let falloffSlots: CGFloat = 1.4
    private let restingSpacing: CGFloat = -10
    private let activeSpacing: CGFloat = 4
    private let leadingPadding: CGFloat = 4
    private let hoverBuffer: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(containerWidth: geo.size.width)

            ZStack {
                ForEach(Array(prompts.enumerated()).reversed(), id: \.element.id) { index, prompt in
                    Button {
                        onSelect(prompt)
                    } label: {
                        PromptChipView(
                            prompt: prompt,
                            tint: prompt.tint.color,
                            size: layout.sizes[index]
                        )
                    }
                    .buttonStyle(.plain)
                    .help(prompt.body)
                    .position(x: layout.centers[index], y: geo.size.height / 2)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let bounds = clusterBounds(containerWidth: geo.size.width)
                    if location.x < bounds.left - hoverBuffer
                        || location.x > bounds.right + hoverBuffer
                    {
                        hoverX = nil
                    } else {
                        hoverX = location.x
                    }
                case .ended:
                    hoverX = nil
                }
            }
        }
        .frame(height: maxSize + 6)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hoverX)
    }

    private func clusterBounds(containerWidth: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let restingStride = baseSize + restingSpacing
        let clusterWidth = baseSize + CGFloat(prompts.count - 1) * restingStride
        return (leadingPadding, leadingPadding + clusterWidth)
    }

    private func computeLayout(containerWidth: CGFloat) -> (sizes: [CGFloat], centers: [CGFloat]) {
        let n = prompts.count
        guard n > 0 else { return ([], []) }

        let bounds = clusterBounds(containerWidth: containerWidth)
        let restingStride = baseSize + restingSpacing

        guard let hoverX else {
            let sizes = Array(repeating: baseSize, count: n)
            let centers = (0..<n).map { i in
                bounds.left + baseSize / 2 + CGFloat(i) * restingStride
            }
            return (sizes, centers)
        }

        // Degenerate case: a single prompt has no neighbors to spread against,
        // and the focusF/lo math below would index past the only element. Just
        // pop it to maxSize on hover.
        guard n > 1 else {
            return ([maxSize], [bounds.left + maxSize / 2])
        }

        let clampedX = max(bounds.left, min(bounds.right, hoverX))
        let restingClusterWidth = max(bounds.right - bounds.left, 1)
        let t = (clampedX - bounds.left) / restingClusterWidth
        let focusF = t * CGFloat(n - 1)

        let sizes = (0..<n).map { i -> CGFloat in
            let dist = abs(CGFloat(i) - focusF)
            let factor = exp(-pow(dist / falloffSlots, 2))
            return baseSize + (maxSize - baseSize) * factor
        }

        var localCenters: [CGFloat] = []
        var cursor: CGFloat = 0
        for i in 0..<n {
            let center = cursor + sizes[i] / 2
            localCenters.append(center)
            cursor += sizes[i] + activeSpacing
        }

        let lo = Int(floor(focusF))
        let hi = min(lo + 1, n - 1)
        let frac = focusF - CGFloat(lo)
        let focusCenterLocal = localCenters[lo] * (1 - frac) + localCenters[hi] * frac
        let focusLeftLocal =
            (localCenters[lo] - sizes[lo] / 2) * (1 - frac)
            + (localCenters[hi] - sizes[hi] / 2) * frac

        // Mirror of the harness-row right-edge cap: keep the focused chip's left
        // edge from sliding past the leading padding when the cursor's near the
        // start of the cluster.
        let intendedShift = clampedX - focusCenterLocal
        let minShift = leadingPadding - focusLeftLocal
        let shift = max(intendedShift, minShift)
        let containerCenters = localCenters.map { $0 + shift }

        return (sizes, containerCenters)
    }
}

private struct PromptChipView: View {
    let prompt: SavedPrompt
    let tint: Color
    let size: CGFloat

    // Reference size at which the text is rendered at 1×. Anything larger or
    // smaller is reached via scaleEffect, which IS animatable (CGAffineTransform).
    // We pin to PromptDockView.baseSize so the text reads at native crispness
    // at rest and scales up under the cursor.
    private let referenceSize: CGFloat = 22

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                // Why scaleEffect (not minimumScaleFactor or size-derived font):
                // .minimumScaleFactor recomputes its scale at each layout pass,
                // so it steps discretely while the surrounding frame interpolates
                // smoothly via spring — the letters end up drifting around inside
                // the circle. scaleEffect is an affine transform that the
                // animation system interpolates frame-by-frame, so the glyph
                // stays locked to the chip.
                Text(prompt.marker)
                    .font(.system(size: referenceSize * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .scaleEffect(size / referenceSize)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.0)
            )
    }
}
