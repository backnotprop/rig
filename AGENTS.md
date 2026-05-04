# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Rig — a small floating macOS sidecar for Ghostty. Creates and focuses Ghostty terminal sessions per "harness" (Pi, Claude, Codex, OpenCode). Hover the screen's left edge to reveal; click a launcher icon to open a new Ghostty window running that harness's command in the selected project's directory.

Targets macOS 26 (Tahoe) / Swift 6. Not a terminal emulator. Doesn't embed Ghostty.

## Critical reading before non-trivial changes

Read `AGENT_NOTES.md` at the repo root. It documents *why* specific pieces of code look weird but can't be naively simplified — autohide window overrides, `@MainActor` on the AppleScript controller, AppleScript `activate` ordering, NSVisualEffectView vs SwiftUI `.glassEffect`, the rsvg-convert vs qlmanage / CoreSVG SVG rendering pitfalls, and focus-anchored launcher magnification math. Multiple sessions have hit the same regressions; the notes exist to prevent the next one.

`SPEC.md` has the original product spec but parts of it are broader than the current MVP.

## Build, run, test

```sh
# Build (Debug, arm64)
xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build build

# Run the built app
open .build/Build/Products/Debug/Rig.app

# Tests (uses a separate derivedData path so it doesn't fight the run-from-CLI build)
xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-test test

# Opt-in: real-Ghostty integration test (creates and focuses a real Ghostty window)
RUN_GHOSTTY_INTEGRATION=1 xcodebuild -project Rig.xcodeproj -scheme Rig \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build-test test
```

When iterating, kill any prior instance and clear persisted state between runs:

```sh
pkill -x Rig
rm -f "$HOME/Library/Application Support/Rig/config.json"
```

## Big-picture architecture

The app is intentionally split between AppKit (window ownership, AppleScript) and SwiftUI (view layer):

- **`AppDelegate`** owns the floating `RigPanel` (an `NSPanel` subclass) directly. SwiftUI's `App` declares only `Settings { EmptyView() }` to satisfy `@main`. **The panel is not a SwiftUI `WindowGroup`** — the WindowGroup-spawned NSWindow can't reliably float across other apps' full-screen Spaces, no matter how its level/collectionBehavior are set. Owning the panel from AppKit is the supported path.
- **`RigAutoHideController`** drives the slide-in/slide-out animation, owns a 1px-wide trigger `NSPanel` anchored at the screen's left edge, and tracks reveal/hide intent. The animation goes through `panel.setFrame(_:display:animate:)` plus three `RigPanel` overrides (`canBecomeKey`, `animationResizeTime`, `constrainFrameRect`). Don't refactor those overrides without reading the notes — each prevents a specific regression.
- **`AppleScriptGhosttyController`** is the only Ghostty bridge. It is `@MainActor` (NSAppleScript needs the main thread / a CFRunLoop) and exposes just two operations: `createWindow(workingDirectory:)` and `focusTerminal(windowId:tabId:terminalId:)`. No state polling; no `closeTerminal`. The MVP is deliberately lean.
- **`ConfigStore`** is the single source of truth for user-configurable state — harnesses, projects, preferences. Persisted as one debounced-save JSON file (`config.json`); views observe via `@EnvironmentObject`. Mutate `store.config.harnesses[i].command = "…"` and the change auto-saves.
- **`SessionListViewModel`** is in-memory only — sessions are runtime references to Ghostty surfaces and not persisted (the IDs go stale the moment Ghostty quits). Coalesces focus requests (latest-wins, cooperative cancellation) so rapid clicks don't queue up.
- **`LauncherRowView`** does the dock-style magnification by computing per-icon sizes via Gaussian falloff over slot-distance from a fractional focus index, then shifting the row so the focus icon's center sits under the cursor (with a per-focus right-edge cap to keep the rightmost icon on-screen).
- **Liquid Glass background** is an `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` wrapped in `VisualEffectBackground` — *not* SwiftUI's `.glassEffect`, which has a stale-blur bug on macOS 26.

The Ghostty controller, view models, and stores all sit behind protocols/initializers that accept dependencies, so tests can inject `FakeGhosttyController` and a temp-file `SessionStore` (see `RigTests/RigTests.swift`).

## Conventions

- Comments are `// Why:` style at load-bearing spots only. Don't narrate what the code does — names already do that. Comment when the code looks like a deletion candidate but isn't.
- Commit messages should document the *why* of changes, not just the *what*. `git log` is part of the design record.
- New `.swift` files must be registered manually in `Rig.xcodeproj/project.pbxproj` (PBXBuildFile + PBXFileReference + group child + Sources phase entry). The project does **not** use synchronized file-system groups.
- `harness-icons/` holds the source SVGs; the corresponding asset entries live in `Rig/Assets.xcassets/<Name>.imageset/`. The Codex asset is a PNG (rendered via `rsvg-convert`) for SVG-renderer compatibility — see AGENT_NOTES.md.
