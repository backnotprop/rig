import AppKit
import ApplicationServices

/// Fast, in-memory lookup from Rig sessions to native Ghostty AX windows.
///
/// Ghostty's AppleScript IDs remain the durable identity. AX elements are cached
/// only so window operations do not have to refocus every session one by one.
@MainActor
enum ManagedGhosttyWindowRegistry {
    private static var windows: [GhosttySession.ID: AXUIElement] = [:]

    @discardableResult
    static func registerFocusedWindow(sessionID: GhosttySession.ID) -> Bool {
        guard let appRef = ghosttyAppRef(),
              let window = focusedWindow(appRef: appRef),
              isValid(window)
        else { return false }

        windows[sessionID] = window
        return true
    }

    @discardableResult
    static func register(sessionID: GhosttySession.ID, windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let appRef = ghosttyAppRef(),
              let window = window(appRef: appRef, matching: windowID),
              isValid(window)
        else { return false }

        windows[sessionID] = window
        return true
    }

    static func window(for sessionID: GhosttySession.ID) -> AXUIElement? {
        guard let window = windows[sessionID] else { return nil }
        guard isValid(window) else {
            windows[sessionID] = nil
            return nil
        }

        return window
    }

    static func remove(_ sessionID: GhosttySession.ID) {
        windows[sessionID] = nil
    }

    static func removeAll() {
        windows.removeAll()
    }

    static func cgWindowID(_ window: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    private static func ghosttyAppRef() -> AXUIElement? {
        guard let pid = SpaceSwitcher.ghosttyPID else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func focusedWindow(appRef: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, attribute as CFString, &value) == .success,
               let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }

        return nil
    }

    private static func window(appRef: AXUIElement, matching targetWindowID: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        return windows.first { window in
            cgWindowID(window) == targetWindowID
        }
    }

    private static func isValid(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value) == .success
    }
}
