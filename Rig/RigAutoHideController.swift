import AppKit

@MainActor
final class RigAutoHideController {
    private let panel: NSPanel
    private let panelWidth: CGFloat
    private var triggerPanel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var revealedFrame: NSRect = .zero
    private var hiddenFrame: NSRect = .zero
    private(set) var isRevealed = true

    private let animationDuration: TimeInterval = 0.18
    private let hideGracePeriod: TimeInterval = 0.3
    private let initialPeekDuration: TimeInterval = 1.5
    private let triggerWidth: CGFloat = 2

    init(panel: NSPanel, panelWidth: CGFloat = 240) {
        self.panel = panel
        self.panelWidth = panelWidth

        recomputeFrames()
        wrapContentViewWithTracking()
        installTriggerPanel()

        panel.setFrame(revealedFrame, display: false)
        scheduleHide(after: initialPeekDuration)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func recomputeFrames() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        revealedFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )
        hiddenFrame = NSRect(
            x: screenFrame.minX - panelWidth - 200,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )
    }

    private func wrapContentViewWithTracking() {
        guard let existing = panel.contentView else { return }

        let container = AutoHideContainerView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        container.frame = panel.contentLayoutRect

        existing.removeFromSuperview()
        existing.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(existing)
        NSLayoutConstraint.activate([
            existing.topAnchor.constraint(equalTo: container.topAnchor),
            existing.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            existing.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            existing.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        container.onMouseEntered = { [weak self] in self?.reveal() }
        container.onMouseExited = { [weak self] in self?.scheduleHide() }

        panel.contentView = container
    }

    private func installTriggerPanel() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }

        let triggerRect = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: triggerWidth,
            height: screenFrame.height
        )

        let trigger = NSPanel(
            contentRect: triggerRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        trigger.isFloatingPanel = true
        trigger.becomesKeyOnlyIfNeeded = false
        trigger.worksWhenModal = true
        trigger.hidesOnDeactivate = false
        trigger.level = .floating
        trigger.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        trigger.isOpaque = false
        trigger.backgroundColor = .clear
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = false

        let triggerView = TriggerView(frame: NSRect(origin: .zero, size: triggerRect.size))
        triggerView.onMouseEntered = { [weak self] in self?.reveal() }
        trigger.contentView = triggerView

        trigger.orderFrontRegardless()
        triggerPanel = trigger
    }

    private func handleScreenChange() {
        recomputeFrames()
        if let trigger = triggerPanel, let screenFrame = NSScreen.main?.visibleFrame {
            trigger.setFrame(
                NSRect(
                    x: screenFrame.minX,
                    y: screenFrame.minY,
                    width: triggerWidth,
                    height: screenFrame.height
                ),
                display: true
            )
        }
        panel.setFrame(isRevealed ? revealedFrame : hiddenFrame, display: true)
    }

    private func reveal() {
        cancelHide()
        guard !isRevealed else { return }
        isRevealed = true
        if !panel.isVisible {
            panel.setFrame(hiddenFrame, display: false)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(revealedFrame, display: true)
        }
    }

    private func scheduleHide(after delay: TimeInterval? = nil) {
        cancelHide()
        let item = DispatchWorkItem { [weak self] in
            self?.hideNow()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? hideGracePeriod),
            execute: item
        )
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func hideNow() {
        guard isRevealed else { return }
        isRevealed = false
        NSAnimationContext.runAnimationGroup({ [panel, hiddenFrame, animationDuration] context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(hiddenFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, !self.isRevealed else { return }
            self.panel.orderOut(nil)
        })
    }
}

private final class AutoHideContainerView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

private final class TriggerView: NSView {
    var onMouseEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }
}
