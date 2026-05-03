import AppKit
import SwiftUI

final class RigPanel: NSPanel {
    var customResizeDuration: TimeInterval = 0.4
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Why: NSWindow's animator() silently ignores NSAnimationContext.duration for
    // setFrame, so the autohide slide uses setFrame(_:display:animate:) instead, which
    // honors this override. Without it, the slide is the system default (~0.2s, scaled
    // by frame delta) and looks instant.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        customResizeDuration
    }

    // Why: macOS auto-clamps off-screen window frames to keep windows partially visible
    // (~50px). That clamp truncates our hidden-frame slide so the panel "stops at 50px
    // and disappears" mid-animation. Returning frameRect unchanged disables it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = SessionListViewModel(
        controller: AppleScriptGhosttyController(),
        store: SessionStore()
    )
    let projectsViewModel = ProjectsViewModel()

    private var panel: RigPanel?
    private var autoHide: RigAutoHideController?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            setupPanel()
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupPanel() {
        let panel = RigPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 360),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        panel.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                .environmentObject(projectsViewModel)
        )

        panel.title = "Rig"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 176, height: 240)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        autoHide = RigAutoHideController(panel: panel)
        panel.orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights(in: panel)
        }

        projectsViewModel.start()

        Task { @MainActor [viewModel] in
            await viewModel.start()
        }

        self.panel = panel
    }

    private func positionTrafficLights(in window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton),
            let buttonSuperview = closeButton.superview
        else {
            return
        }

        let topInset: CGFloat = 18
        let leadingInset: CGFloat = 18
        let spacing: CGFloat = 22
        let y = buttonSuperview.bounds.height - topInset - closeButton.frame.height
        guard y.isFinite else { return }

        closeButton.setFrameOrigin(NSPoint(x: leadingInset, y: y))
        minimizeButton.setFrameOrigin(NSPoint(x: leadingInset + spacing, y: y))
        zoomButton.setFrameOrigin(NSPoint(x: leadingInset + spacing * 2, y: y))
    }
}
