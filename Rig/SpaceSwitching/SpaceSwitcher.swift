import AppKit
import Foundation

/// Swift facade over the C SpaceSwitching engine. Owns init/destroy lifecycle,
/// listens for macOS Space-change notifications to reset predictions, and
/// provides the one call Rig's focus flow needs: "switch to whatever Space
/// this CGWindowID lives on."
@MainActor
final class SpaceSwitcher {
    private var isInitialized = false
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    /// Set by AppDelegate after panel creation. During a Space switch the panel
    /// is temporarily raised to .popUpMenu so it can't flash behind Ghostty.
    weak var floatingPanel: NSPanel?

    init() {
        if !CGPreflightPostEventAccess() {
            CGRequestPostEventAccess()
        }

        isInitialized = rig_space_init()
        if isInitialized {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                rig_space_reset_predictions()
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        rig_space_destroy()
    }

    /// Switch to the Space that `windowID` lives on. No-op if already there,
    /// the window can't be found, or Space info is unavailable.
    func switchToSpaceOf(windowID: CGWindowID) {
        guard isInitialized else { return }

        let targetIndex = rig_space_index_for_window(windowID)
        if targetIndex < 0 { return }

        var info = RigSpaceInfo()
        guard rig_space_get_info(&info) else { return }
        if info.currentIndex == UInt32(targetIndex) { return }

        raisePanel()
        rig_space_switch_to_index(UInt32(targetIndex))
    }

    /// Raise Rig's panel above everything so activated-app windows can't
    /// flash on top during a Space switch + focus sequence.
    func raisePanel() {
        floatingPanel?.level = .popUpMenu
    }

    /// Restore the panel to its normal floating level. The ViewModel calls
    /// this AFTER the AppleScript focus completes so the panel stays raised
    /// through the entire transition.
    func restorePanel() {
        floatingPanel?.level = .floating
    }

    /// Find the CGWindowID for a Ghostty window we just created. Matches by
    /// owner PID; returns the highest (newest) CGWindowID belonging to that
    /// PID. Call immediately after AppleScript `new window` so the newest
    /// window is ours.
    static func newestWindowID(ownerPID: pid_t) -> CGWindowID? {
        // .optionAll instead of .optionOnScreenOnly — the window may not be
        // composited on-screen yet at the instant AppleScript returns.
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var best: CGWindowID? = nil
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid == ownerPID,
                  let wid = entry[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            // Highest windowID = most recently created.
            if best == nil || wid > (best ?? 0) {
                best = wid
            }
        }
        return best
    }

    /// Convenience: find Ghostty.app's PID from its bundle ID.
    static var ghosttyPID: pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first?.processIdentifier
    }
}
