import AppKit
import SwiftUI

struct LauncherRowView: View {
    let harnesses: [Harness]
    let isDisabled: Bool
    let onTap: (Harness) -> Void

    @State private var hoverX: CGFloat?

    private let baseSize: CGFloat = 28
    private let maxSize: CGFloat = 44
    private let falloffSlots: CGFloat = 1.4
    private let restingSpacing: CGFloat = -14
    private let activeSpacing: CGFloat = 6
    private let trailingPadding: CGFloat = 8
    private let hoverBuffer: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let layout = computeLayout(containerWidth: geo.size.width)

            ZStack {
                ForEach(Array(harnesses.enumerated()).reversed(), id: \.element.id) { index, harness in
                    Button {
                        onTap(harness)
                    } label: {
                        LauncherIconView(harness: harness, size: layout.sizes[index])
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .help(harness.label)
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
        .mask(edgeMask)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hoverX)
    }

    private func clusterBounds(containerWidth: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let restingStride = baseSize + restingSpacing
        let clusterWidth = baseSize + CGFloat(harnesses.count - 1) * restingStride
        let right = containerWidth - trailingPadding
        return (right - clusterWidth, right)
    }

    private func computeLayout(containerWidth: CGFloat) -> (sizes: [CGFloat], centers: [CGFloat]) {
        let n = harnesses.count
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

        let intendedShift = clampedX - focusCenterLocal
        let focusRightLocal =
            (localCenters[lo] + sizes[lo] / 2) * (1 - frac)
            + (localCenters[hi] + sizes[hi] / 2) * frac
        let maxShift = (containerWidth - trailingPadding) - focusRightLocal
        let shift = min(intendedShift, maxShift)
        let containerCenters = localCenters.map { $0 + shift }

        return (sizes, containerCenters)
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.20),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct LauncherIconView: View {
    let harness: Harness
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(harness.tint.color)
            .frame(width: size, height: size)
            .overlay(iconImage.padding(size * harness.iconInset))
            .clipShape(Circle())
            // Thin hairline ring so overlapping black circles read as distinct
            // (Slack / iMessage stacked-avatar idiom). Above the clipShape so the
            // ring isn't trimmed at the seam.
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.2)
            )
    }

    @ViewBuilder
    private var iconImage: some View {
        switch harness.icon {
        case .builtin(let name):
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .file(let url):
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    LauncherRowView(
        harnesses: Harness.builtinDefaults,
        isDisabled: false,
        onTap: { _ in }
    )
    .padding()
    .frame(width: 240)
    .background(Color.gray.opacity(0.2))
}
