import AppKit

@MainActor
final class RigAutoHideController {
    private let panel: NSPanel
    private var panelWidth: CGFloat
    private var triggerPanel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var revealedFrame: NSRect = .zero
    private var tuckedFrame: NSRect = .zero
    private var hiddenFrame: NSRect = .zero
    private(set) var isRevealed = true
    private(set) var isTucked = false
    private let peekWidth: CGFloat = 40
    /// True between willStartLiveResize and didEndLiveResize. Suppresses every
    /// hide path so the panel can't slide away under the user's cursor while
    /// they're actively dragging the edge.
    private var isResizing = false

    private let animationDuration: TimeInterval = 0.40
    /// 0.8s (was 0.3s): the old grace was tight enough that moving the cursor
    /// to the panel's right edge to grab the resize affordance was racing the
    /// hide timer. 0.8s is forgiving for "I'm reaching for the edge" without
    /// being so long that the panel feels sluggish on a casual mouseout.
    private let hideGracePeriod: TimeInterval = 0.8
    private let initialPeekDuration: TimeInterval = 1.5
    private let triggerWidth: CGFloat = 1
    private let revealDelay: TimeInterval = 0.6
    private var revealWorkItem: DispatchWorkItem?

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
        NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleResizeStart() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleResizeEnd() }
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
        tuckedFrame = NSRect(
            x: screenFrame.minX - panelWidth + peekWidth,
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
            existing.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.onMouseEntered = { [weak self] in
            guard let self else { return }
            // When tucked, only a click reveals — hover is ignored so the
            // user's cursor position after switching sessions doesn't
            // accidentally re-open the sidebar.
            if !self.isTucked { self.reveal() }
        }
        container.onMouseExited = { [weak self] in
            guard let self else { return }
            // Don't override the tuck timer with the shorter grace period.
            if !self.isTucked { self.scheduleHide() }
        }
        container.onMouseDown = { [weak self] in
            guard let self, self.isTucked else { return }
            self.reveal()
        }

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
            .stationary,
        ]
        trigger.isOpaque = false
        trigger.backgroundColor = .clear
        trigger.hasShadow = false
        trigger.ignoresMouseEvents = false

        let triggerView = TriggerView(frame: NSRect(origin: .zero, size: triggerRect.size))
        triggerView.onMouseEntered = { [weak self] in self?.scheduleReveal() }
        triggerView.onMouseExited = { [weak self] in self?.cancelScheduledReveal() }
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

    private func scheduleReveal() {
        cancelScheduledReveal()
        guard !isRevealed else {
            cancelHide()
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.reveal() }
        revealWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: item)
    }

    private func cancelScheduledReveal() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
    }

    private func reveal() {
        cancelHide()
        cancelScheduledReveal()
        guard !isRevealed else { return }
        isRevealed = true
        isTucked = false
        if !panel.isVisible {
            panel.setFrame(hiddenFrame, display: false)
            panel.orderFrontRegardless()
        }
        if let rigPanel = panel as? RigPanel {
            rigPanel.customResizeDuration = animationDuration
        }
        panel.setFrame(revealedFrame, display: true, animate: true)
    }

    /// Slide Rig mostly off-screen, leaving only `peekWidth` visible.
    /// Used after switching sessions so Ghostty gets the full screen and
    /// Rig is just a small grab-tab on the left edge. If the user doesn't
    /// click the tab within a few seconds, it slides fully off.
    func tuck() {
        cancelHide()
        cancelScheduledReveal()
        isTucked = true
        isRevealed = false
        if let rigPanel = panel as? RigPanel {
            rigPanel.customResizeDuration = 0.25
        }
        panel.setFrame(tuckedFrame, display: true, animate: true)

        // If user doesn't click the peek within 2.5s, hide completely.
        scheduleHide(after: 2.5)
    }

    private func scheduleHide(after delay: TimeInterval? = nil) {
        // Live-resize wins. The user is actively dragging the panel; the
        // mouse is by definition outside the contentView's tracking area
        // during a resize, but they obviously don't want it to vanish.
        if isResizing { return }
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

    private func handleResizeStart() {
        isResizing = true
        cancelHide()
        cancelScheduledReveal()
    }

    private func handleResizeEnd() {
        isResizing = false
        // Bake the user's chosen width into our cached frames so the next
        // reveal/hide uses it instead of snapping back to the launch width.
        panelWidth = panel.frame.width
        recomputeFrames()

        // If the cursor isn't currently over the panel after the gesture,
        // restart the hide timer — they presumably moved away to drag and
        // may continue away.
        if !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleHide()
        }
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func hideNow() {
        guard isRevealed || isTucked else { return }
        isRevealed = false
        isTucked = false
        if let rigPanel = panel as? RigPanel {
            rigPanel.customResizeDuration = animationDuration
        }
        panel.setFrame(hiddenFrame, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.02) { [weak self] in
            guard let self, !self.isRevealed, !self.isTucked else { return }
            self.panel.orderOut(nil)
        }
    }
}

private final class AutoHideContainerView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        if let onMouseDown {
            onMouseDown()
        } else {
            super.mouseDown(with: event)
        }
    }

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
    var onMouseExited: (() -> Void)?
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

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}
