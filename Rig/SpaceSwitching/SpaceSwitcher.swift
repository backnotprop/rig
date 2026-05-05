import AppKit
import Foundation

@MainActor
final class SpaceSwitcher {
    private var isInitialized = false
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    weak var rigPanel: NSPanel?

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

    func switchToSpaceOf(windowID: CGWindowID) {
        guard isInitialized else { return }

        let targetIndex = rig_space_index_for_window(windowID)
        if targetIndex < 0 { return }

        var info = RigSpaceInfo()
        guard rig_space_get_info(&info) else { return }
        if info.currentIndex == UInt32(targetIndex) { return }

        rig_space_switch_to_index(UInt32(targetIndex))
    }

    static func newestWindowID(ownerPID: pid_t) -> CGWindowID? {
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
            if best == nil || wid > (best ?? 0) {
                best = wid
            }
        }
        return best
    }

    static var ghosttyPID: pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first?.processIdentifier
    }
}
