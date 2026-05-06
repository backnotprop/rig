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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let configStore = ConfigStore()
    let viewModel = SessionListViewModel(
        controller: AppleScriptGhosttyController()
    )

    private var panel: RigPanel?
    private var autoHide: RigAutoHideController?
    private var settingsWindow: NSWindow?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            setupPanel()
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            configStore.flushPendingSave()
        }
    }

    private func setupPanel() {
        // Why .nonactivatingPanel: it's required for isFloatingPanel = true to actually
        // float over other apps' full-screen Spaces. Without it, the panel falls back
        // to normal-window behavior and stops appearing over full-screen content.
        // Trade-off: clicks on the panel don't activate the app, so Cmd+, / menu-bar
        // access don't work without dock-clicking. We mitigate that by exposing
        // Settings via a gear button inside the panel UI itself.
        let panel = RigPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 360),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )

        panel.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
                .environmentObject(configStore)
                .environmentObject(self)
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
        panel.level = .modalPanel
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]

        autoHide = RigAutoHideController(panel: panel)
        panel.orderFrontRegardless()
        viewModel.spaceSwitcher.rigPanel = panel
        viewModel.onSessionSwitched = { [weak self] in
            self?.autoHide?.tuck()
        }
        autoHide?.onReveal = { [weak self] in
            self?.viewModel.refreshSessionTitles()
        }



        DispatchQueue.main.async { [weak self] in
            self?.positionTrafficLights(in: panel)
        }

        Task { @MainActor [viewModel] in
            await viewModel.start()
        }

        self.panel = panel
    }

    func presentSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView()
            .environmentObject(configStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rig Settings"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
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
