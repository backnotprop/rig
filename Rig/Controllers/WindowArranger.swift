import AppKit
import ApplicationServices

/// Arranges Rig-managed Ghostty windows on the current screen.
@MainActor
enum WindowArranger {
    private static func log(_ msg: String) {
        let path = "/tmp/rig-arrange-debug.log"
        let line = msg + "\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    enum Layout {
        case cascade
        case grid
        case sideBySide
        case fillScreen
    }

    private enum SharedSpaceError: LocalizedError {
        case ghosttyWindowUnavailable
        case browserWindowUnavailable

        var errorDescription: String? {
            switch self {
            case .ghosttyWindowUnavailable:
                "Rig could not find that Ghostty window for split view."
            case .browserWindowUnavailable:
                "Rig opened the URL, but could not find the browser window to arrange."
            }
        }
    }

    private struct TargetFrame {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    /// Arranges Rig's session windows by using Ghostty scripting IDs for
    /// identity and Accessibility only for native window state/placement.
    static func arrange(sessions: [GhosttySession], layout: Layout) async {
        guard !sessions.isEmpty else { return }

        let captured = await captureWindows(for: sessions)
        Self.log("[ARRANGE] captured \(captured.count) windows for \(sessions.count) sessions")
        guard !captured.isEmpty else { return }

        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let targetFrames = targetFrames(count: captured.count, layout: layout, in: frame)

        let enhancedUIRestore = disableEnhancedUserInterface()
        defer {
            restoreEnhancedUserInterface(enhancedUIRestore)
        }

        var didExitFullScreen = false
        for (index, item) in captured.enumerated() where isFullScreen(item.window) {
            applyFrame(targetFrames[index], to: item.window)
            if setFullScreen(item.window, false) {
                didExitFullScreen = true
                Self.log("[ARRANGE] exited fullscreen for \(item.session.ghosttyWindowId)")
            }
        }

        if didExitFullScreen {
            for delay in [160, 260, 320, 320] {
                try? await Task.sleep(for: .milliseconds(delay))
                applyFrames(targetFrames, to: captured)
            }
        }

        let ready = captured.enumerated().compactMap { index, item -> (window: AXUIElement, targetFrame: TargetFrame)? in
            let window = ManagedGhosttyWindowRegistry.window(for: item.session.id) ?? item.window
            guard !isFullScreen(window), isNormalWindow(window) else {
                Self.log("[ARRANGE] skipped \(item.session.ghosttyWindowId): window not ready for layout")
                return nil
            }

            return (window, targetFrames[index])
        }
        guard !ready.isEmpty else { return }

        for item in ready {
            applyFrame(item.targetFrame, to: item.window)
            raise(item.window)
        }
    }

    /// Exits macOS native fullscreen for managed windows before lifecycle
    /// operations. This deliberately does not position the windows; AppKit
    /// restores their normal frames and then the caller can close them.
    static func exitNativeFullScreen(sessions: [GhosttySession]) async {
        guard !sessions.isEmpty else { return }

        let captured = await captureWindows(for: sessions)
        let fullScreenWindows = captured.filter { isFullScreen($0.window) }
        guard !fullScreenWindows.isEmpty else { return }

        let enhancedUIRestore = disableEnhancedUserInterface()
        defer {
            restoreEnhancedUserInterface(enhancedUIRestore)
        }

        for item in fullScreenWindows {
            if setFullScreen(item.window, false) {
                Self.log("[ARRANGE] close-prep exited fullscreen for \(item.session.ghosttyWindowId)")
            }
        }

        try? await Task.sleep(for: .milliseconds(900))
    }

    static func openURLInSharedSpace(_ url: URL, beside session: GhosttySession) async throws {
        guard let ghosttyWindow = await resolveWindow(for: session) else {
            throw SharedSpaceError.ghosttyWindowUnavailable
        }
        guard let screen = NSScreen.main else { return }

        let targetFrames = sideBySideFrames(count: 2, in: screen.visibleFrame)
        let ghosttyFrame = targetFrames[0]
        let browserFrame = targetFrames[1]

        let enhancedUIRestore = disableEnhancedUserInterface()
        defer {
            restoreEnhancedUserInterface(enhancedUIRestore)
        }

        await prepare(window: ghosttyWindow, for: ghosttyFrame)
        raise(ghosttyWindow)

        guard let browserWindow = await openURLAndResolveBrowserWindow(url) else {
            throw SharedSpaceError.browserWindowUnavailable
        }

        let currentGhosttyWindow = ManagedGhosttyWindowRegistry.window(for: session.id) ?? ghosttyWindow
        await prepare(window: currentGhosttyWindow, for: ghosttyFrame)
        await prepare(window: browserWindow, for: browserFrame)

        raise(currentGhosttyWindow)
        raise(browserWindow)
    }

    static func openURLInNativeSplitView(_ url: URL, beside session: GhosttySession) async throws {
        let browserBundleID = defaultApplicationBundleIdentifier(for: url)

        // Establish a clean normal-window pair first. This makes the native
        // Split View picker much more likely to show the intended Ghostty
        // candidate on the opposite side of the screen.
        try await openURLInSharedSpace(url, beside: session)
        try? await Task.sleep(for: .milliseconds(250))

        guard triggerTileRightForApplication(bundleID: browserBundleID) else {
            throw SharedSpaceError.browserWindowUnavailable
        }

        // macOS now owns the Split View picker. There is no public API to pick
        // the second window, so this prototype clicks the Ghostty half after
        // giving Mission Control time to expose the candidate windows.
        try? await Task.sleep(for: .milliseconds(900))
        clickLeftSplitCandidate()
    }

    private static func captureWindows(for sessions: [GhosttySession]) async -> [(session: GhosttySession, window: AXUIElement)] {
        var captured: [(session: GhosttySession, window: AXUIElement)] = []
        var seenWindowIDs = Set<CGWindowID>()

        for session in sessions {
            guard let axWindow = await resolveWindow(for: session) else {
                Self.log("[ARRANGE] skipped \(session.ghosttyWindowId): no AX window")
                continue
            }

            if let windowID = ManagedGhosttyWindowRegistry.cgWindowID(axWindow) {
                guard seenWindowIDs.insert(windowID).inserted else {
                    Self.log("[ARRANGE] skipped duplicate CGWindowID \(windowID) for \(session.ghosttyWindowId)")
                    continue
                }
            }

            captured.append((session, axWindow))
        }

        return captured
    }

    // MARK: - Layouts

    private static func targetFrames(count: Int, layout: Layout, in frame: NSRect) -> [TargetFrame] {
        switch layout {
        case .cascade:
            cascadeFrames(count: count, in: frame)
        case .grid:
            gridFrames(count: count, in: frame)
        case .sideBySide:
            sideBySideFrames(count: count, in: frame)
        case .fillScreen:
            fillScreenFrames(count: count, in: frame)
        }
    }

    private static func cascadeFrames(count: Int, in frame: NSRect) -> [TargetFrame] {
        let windowWidth = frame.width * 0.7
        let windowHeight = frame.height * 0.7
        let offsetX: CGFloat = 30
        let offsetY: CGFloat = 30

        return (0..<count).map { i in
            let x = frame.origin.x + CGFloat(i) * offsetX
            let y = frame.origin.y + frame.height - windowHeight - CGFloat(i) * offsetY
            return TargetFrame(
                x: x,
                y: screenFlipY(y, height: windowHeight),
                width: windowWidth,
                height: windowHeight
            )
        }
    }

    private static func gridFrames(count: Int, in frame: NSRect) -> [TargetFrame] {
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellWidth = frame.width / CGFloat(cols)
        let cellHeight = frame.height / CGFloat(rows)

        return (0..<count).map { i in
            let col = i % cols
            let row = i / cols
            let x = frame.origin.x + CGFloat(col) * cellWidth
            let y = frame.origin.y + frame.height - CGFloat(row + 1) * cellHeight
            return TargetFrame(
                x: x,
                y: screenFlipY(y, height: cellHeight),
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    private static func sideBySideFrames(count: Int, in frame: NSRect) -> [TargetFrame] {
        let cellWidth = frame.width / CGFloat(count)

        return (0..<count).map { i in
            let x = frame.origin.x + CGFloat(i) * cellWidth
            return TargetFrame(
                x: x,
                y: screenFlipY(frame.origin.y, height: frame.height),
                width: cellWidth,
                height: frame.height
            )
        }
    }

    private static func fillScreenFrames(count: Int, in frame: NSRect) -> [TargetFrame] {
        let targetFrame = TargetFrame(
            x: frame.origin.x,
            y: screenFlipY(frame.origin.y, height: frame.height),
            width: frame.width,
            height: frame.height
        )

        return Array(repeating: targetFrame, count: count)
    }

    private static func applyFrames(
        _ targetFrames: [TargetFrame],
        to captured: [(session: GhosttySession, window: AXUIElement)]
    ) {
        for (index, item) in captured.enumerated() where targetFrames.indices.contains(index) {
            let window = ManagedGhosttyWindowRegistry.window(for: item.session.id) ?? item.window
            applyFrame(targetFrames[index], to: window)
        }
    }

    private static func applyFrame(_ targetFrame: TargetFrame, to window: AXUIElement) {
        setSize(window, width: targetFrame.width, height: targetFrame.height)
        setPosition(window, x: targetFrame.x, y: targetFrame.y)
        setSize(window, width: targetFrame.width, height: targetFrame.height)
    }

    private static func prepare(window: AXUIElement, for targetFrame: TargetFrame) async {
        setMiniaturized(window, false)
        applyFrame(targetFrame, to: window)

        if isFullScreen(window) {
            _ = setFullScreen(window, false)
            for delay in [140, 220, 280, 360] {
                try? await Task.sleep(for: .milliseconds(delay))
                applyFrame(targetFrame, to: window)
            }
        }

        if !isFullScreen(window), isNormalWindow(window) {
            applyFrame(targetFrame, to: window)
        }
    }

    // MARK: - Window identification

    private static func resolveWindow(for session: GhosttySession) async -> AXUIElement? {
        if let window = ManagedGhosttyWindowRegistry.window(for: session.id) {
            return window
        }

        if ManagedGhosttyWindowRegistry.register(sessionID: session.id, windowID: session.cgWindowID),
           let window = ManagedGhosttyWindowRegistry.window(for: session.id) {
            return window
        }

        guard focusSessionViaAppleScript(session) else { return nil }
        try? await Task.sleep(for: .milliseconds(180))

        guard ManagedGhosttyWindowRegistry.registerFocusedWindow(sessionID: session.id) else {
            return nil
        }

        return ManagedGhosttyWindowRegistry.window(for: session.id)
    }

    private static func focusSessionViaAppleScript(_ session: GhosttySession) -> Bool {
        let source = """
        tell application "Ghostty"
            set expectedWindowId to \(appleScriptLiteral(session.ghosttyWindowId))
            set expectedTerminalId to \(appleScriptLiteral(session.ghosttyTerminalId))

            set targetWin to missing value
            set winCount to 0
            try
                set winCount to count of windows
            end try
            repeat with winIdx from 1 to winCount
                try
                    set winRef to window winIdx
                    if (id of winRef as text) is expectedWindowId then
                        set targetWin to winRef
                        exit repeat
                    end if
                end try
            end repeat
            if targetWin is missing value then error "Rig could not find the managed Ghostty window."

            set targetTerm to missing value
            set termCount to 0
            try
                set termCount to count of terminals of targetWin
            end try
            repeat with termIdx from 1 to termCount
                try
                    set termRef to terminal termIdx of targetWin
                    if (id of termRef as text) is expectedTerminalId then
                        set targetTerm to termRef
                        exit repeat
                    end if
                end try
            end repeat
            if targetTerm is missing value then error "Rig could not find the managed Ghostty terminal."

            try
                set visible of targetWin to true
            end try
            try
                set miniaturized of targetWin to false
            end try

            activate window targetWin
            focus targetTerm
            return id of targetWin as text
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            Self.log("[ARRANGE] AppleScript focus error for \(session.ghosttyWindowId): \(message)")
            return false
        }

        return result.stringValue == session.ghosttyWindowId
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        return "\"\(escaped)\""
    }

    // MARK: - Browser companion window

    private static func openURLAndResolveBrowserWindow(_ url: URL) async -> AXUIElement? {
        let bundleID = defaultApplicationBundleIdentifier(for: url)
        let existingWindowIDs = windowIDs(forApplicationWithBundleID: bundleID)

        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }

        for delay in [120, 180, 240, 360, 500, 700, 900] {
            try? await Task.sleep(for: .milliseconds(delay))
            if let window = browserWindow(bundleID: bundleID, excluding: existingWindowIDs) {
                return window
            }
        }

        return nil
    }

    private static func defaultApplicationBundleIdentifier(for url: URL) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private static func browserWindow(
        bundleID: String?,
        excluding existingWindowIDs: Set<CGWindowID>
    ) -> AXUIElement? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
           frontmost.bundleIdentifier != "com.mitchellh.ghostty",
           bundleID == nil || frontmost.bundleIdentifier == bundleID,
           let window = window(forApplicationPID: frontmost.processIdentifier, excluding: existingWindowIDs) {
            return window
        }

        guard let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }

        return window(forApplicationPID: app.processIdentifier, excluding: existingWindowIDs)
    }

    private static func windowIDs(forApplicationWithBundleID bundleID: String?) -> Set<CGWindowID> {
        guard let bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return [] }

        return Set(windows(forApplicationPID: app.processIdentifier).compactMap(ManagedGhosttyWindowRegistry.cgWindowID))
    }

    private static func window(forApplicationPID pid: pid_t, excluding existingWindowIDs: Set<CGWindowID>) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, attribute as CFString, &value) == .success,
               let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }

        let windows = windows(forApplicationPID: pid)
        if let newWindow = windows.first(where: { window in
            guard let windowID = ManagedGhosttyWindowRegistry.cgWindowID(window) else { return false }
            return !existingWindowIDs.contains(windowID)
        }) {
            return newWindow
        }

        return windows.first(where: isNormalWindow)
    }

    private static func windows(forApplicationPID pid: pid_t) -> [AXUIElement] {
        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }

        return windows
    }

    // MARK: - Native Split View prototype

    private static func triggerTileRightForApplication(bundleID: String?) -> Bool {
        let itemNames = [
            "Tile Window to Right of Screen",
            "Tile Window to Right Side of Screen",
            "Move Window to Right Side of Screen",
            "Move Window to Right of Screen",
        ]

        let bundleClause: String
        if let bundleID {
            bundleClause = """
            repeat with proc in application processes
                try
                    if bundle identifier of proc is \(appleScriptLiteral(bundleID)) then
                        set targetProcess to proc
                        exit repeat
                    end if
                end try
            end repeat
            """
        } else {
            bundleClause = ""
        }

        let itemList = itemNames.map(appleScriptLiteral).joined(separator: ", ")
        let source = """
        tell application "System Events"
            set targetProcess to missing value
            \(bundleClause)
            if targetProcess is missing value then
                set targetProcess to first application process whose frontmost is true
            end if

            tell targetProcess
                set frontmost to true
                repeat with itemName in {\(itemList)}
                    try
                        click menu item (itemName as text) of menu "Window" of menu bar 1
                        return itemName as text
                    end try
                end repeat
            end tell
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            Self.log("[ARRANGE] native split menu error: \(message)")
            return false
        }

        Self.log("[ARRANGE] native split triggered menu item: \(result.stringValue ?? "unknown")")
        return true
    }

    private static func clickLeftSplitCandidate() {
        guard let screen = NSScreen.main else { return }

        let x = screen.frame.minX + screen.frame.width * 0.25
        let y = screen.frame.height - (screen.frame.origin.y + screen.frame.height * 0.5)
        let point = CGPoint(x: x, y: y)

        let source = CGEventSource(stateID: .hidSystemState)
        let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )

        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    private static func isFullScreen(_ win: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &value) == .success,
              let isFullScreen = value as? Bool
        else { return false }

        return isFullScreen
    }

    private static func setFullScreen(_ win: AXUIElement, _ fullScreen: Bool) -> Bool {
        let error = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, fullScreen as CFTypeRef)
        if error != .success {
            Self.log("[ARRANGE] AXFullScreen set failed: \(error.rawValue)")
            return false
        }

        return true
    }

    private static func setMiniaturized(_ win: AXUIElement, _ miniaturized: Bool) {
        AXUIElementSetAttributeValue(
            win,
            kAXMinimizedAttribute as CFString,
            miniaturized as CFTypeRef
        )
    }

    private static func disableEnhancedUserInterface() -> (appRef: AXUIElement, wasEnabled: Bool)? {
        guard let pid = SpaceSwitcher.ghosttyPID else { return nil }

        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, "AXEnhancedUserInterface" as CFString, &value) == .success,
              let wasEnabled = value as? Bool
        else { return nil }

        if wasEnabled {
            AXUIElementSetAttributeValue(
                appRef,
                "AXEnhancedUserInterface" as CFString,
                false as CFTypeRef
            )
        }

        return (appRef, wasEnabled)
    }

    private static func restoreEnhancedUserInterface(_ state: (appRef: AXUIElement, wasEnabled: Bool)?) {
        guard let state, state.wasEnabled else { return }
        AXUIElementSetAttributeValue(
            state.appRef,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    private static func isNormalWindow(_ win: AXUIElement) -> Bool {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef
        else { return false }

        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return false }
        return size.width > 100 && size.height > 100
    }

    private static func setPosition(_ win: AXUIElement, x: CGFloat, y: CGFloat) {
        var point = CGPoint(x: x, y: y)
        if let val = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, val)
        }
    }

    private static func setSize(_ win: AXUIElement, width: CGFloat, height: CGFloat) {
        var size = CGSize(width: width, height: height)
        if let val = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, val)
        }
    }

    private static func raise(_ win: AXUIElement) {
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// AX uses top-left screen coordinates; NSScreen uses bottom-left.
    private static func screenFlipY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        guard let screen = NSScreen.main else { return y }
        return screen.frame.height - y - height
    }
}

/// Private but stable AX function to get CGWindowID from an AXUIElement.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
