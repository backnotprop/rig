import SwiftUI

struct LauncherHarness: Identifiable, Equatable {
    let id: String
    let label: String
    var command: String
    var enabled: Bool = true
    let assetName: String
    let background: Color
    var innerDisc: Color? = nil
    var innerInset: CGFloat = 0.10
    var iconInset: CGFloat = 0.16
}

extension LauncherHarness {
    static let defaults: [LauncherHarness] = [
        LauncherHarness(
            id: "pi",
            label: "Pi",
            command: "pi",
            assetName: "Pi",
            background: .black
        ),
        LauncherHarness(
            id: "claude-code",
            label: "Claude Code",
            command: "claude",
            assetName: "Claude",
            background: .black
        ),
        // Codex asset is a PNG (not SVG) rendered by `rsvg-convert` (librsvg).
        // Its source SVG uses linearGradient gradientUnits="userSpaceOnUse" which both
        // Xcode's vector preservation and CoreSVG mishandle, and qlmanage silently
        // serves a generic-thumbnail fallback regardless of input. See AGENT_NOTES.md.
        LauncherHarness(
            id: "codex",
            label: "Codex",
            command: "codex",
            assetName: "Codex",
            background: .black
        ),
        LauncherHarness(
            id: "opencode",
            label: "OpenCode",
            command: "opencode",
            assetName: "OpenCode",
            background: .black,
            iconInset: 0.24
        )
    ]
}
