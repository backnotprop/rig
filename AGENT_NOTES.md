# Rig — Agent Notes

These are findings, decisions, and load-bearing details discovered while building Rig.
Read this before making non-trivial changes — many "obvious refactors" here will regress
real bugs that took multiple sessions to track down.

## What Rig is

A small floating macOS sidecar that creates and focuses Ghostty terminal sessions per
"harness" (Pi, Claude, Codex, OpenCode). Hover the very left edge of the screen → Rig
slides in. Click a launcher icon → a new Ghostty window opens running that harness's
command in the currently selected project's directory.

It is not a terminal emulator. It does not embed Ghostty. See `SPEC.md` for the
original product spec.

## Architecture (load-bearing)

### NSPanel, not SwiftUI WindowGroup

The window is created in `AppDelegate.applicationDidFinishLaunching` as a custom
`RigPanel: NSPanel` with `NSHostingView<ContentView>` as its content. The SwiftUI `App`
declares only `Settings { EmptyView() }` to satisfy `@main`.

**Why:** `WindowGroup` produces an `NSWindow` whose baked-in behavior prevents proper
"always-on-top across other apps' full-screen Spaces" — even with the right
`level` / `collectionBehavior` set, the configuration does not reliably hold. NSPanel
with `.nonactivatingPanel` styleMask + `isFloatingPanel = true` +
`.canJoinAllSpaces` is the supported path. We tried `object_setClass` to swap the
SwiftUI-spawned window's class to NSPanel; that hack works in some setups but SwiftUI's
window machinery kept reasserting the configuration. Owning the panel from
AppDelegate avoids the fight entirely.

### `@MainActor` controller

`AppleScriptGhosttyController` is `@MainActor`, **not** an `actor`.

**Why:** `NSAppleScript.executeAndReturnError` requires a thread with a CFRunLoop
and is unreliable off-main. Off-main, it returns stale `front window` references
and the "click + → focuses host terminal" bug returns. Don't refactor to `actor`
for "free concurrency"; it's a regression.

### `createWindow` activates Ghostty *after* the new window exists

In the AppleScript: snapshot windows → `new window with configuration cfg` →
identify the new surface → `select tab` + `focus terminal` → (no explicit
`activate`; `focus` brings the window forward).

**Why:** if `activate` happens *before* `new window`, macOS makes Ghostty frontmost
first. If Ghostty's existing frontmost window is on a full-screen Space, the screen
yanks there before the new window even exists. With activation deferred, the new
window is what gets brought forward.

### No queryState, no polling

The session list maintains state through user actions only (createSession on +;
focusTerminal on click; remove on context menu). There used to be a 10-second
`queryState` poll; it was removed because the synchronous AppleScript blocked the
main thread, colliding with user clicks and creating "random switch lag."

If you want to reconcile state with reality (e.g., a session was closed in Ghostty
directly), the current MVP just lets the next click fail and surface an error.
**Don't reintroduce polling without a non-blocking implementation.**

## Window animation (autohide)

### `RigPanel` overrides

Three overrides in `RigPanel`, all load-bearing:

- `canBecomeKey` / `canBecomeMain` → `true`. NSPanel default is "no" for these,
  which prevents keyboard focus on the panel.
- `animationResizeTime(_:)` → returns our `customResizeDuration`. Default returns a
  value scaled by frame delta; for our slide it's tiny → looks instant.
- `constrainFrameRect(_:to:)` → returns `frameRect` unchanged. Default clamps
  off-screen frames to keep windows partially visible (~50px), which truncates the
  slide animation ("stops at 50px and disappears" symptom).

### Hidden frame is `panelWidth + 200` off-screen

`recomputeFrames` uses `screenFrame.minX - panelWidth - 200`. The `+200` is
belt-and-suspenders past the clamp. RigPanel disables the clamp, but the extra buffer
protects against residual clamping on multi-display / Spaces edge cases.

### `setFrame(_:display:animate:)` over `animator()`

Window frame animation uses `panel.setFrame(rect, display: true, animate: true)`,
not `panel.animator().setFrame(...)` inside an `NSAnimationContext`.

**Why:** NSWindow's `animator()` proxy silently ignores `NSAnimationContext.duration`
for window frames and uses `animationResizeTime(for:)` instead. The
`setFrame(_:display:animate:)` form respects our override.

### `orderOut` after hide animation, `orderFront` before reveal

`hideNow` schedules `orderOut(nil)` after the animation completes. `reveal`
`orderFront`s before animating, with the panel's frame pre-set to hidden so the slide
starts off-screen.

## Liquid Glass (macOS 26 Tahoe quirks)

### Use `NSVisualEffectView`, not SwiftUI `.glassEffect`, for the panel background

The outer panel background is `NSVisualEffectView(material: .hudWindow,
blendingMode: .behindWindow)` (wrapped in `VisualEffectBackground`).

**Why:** SwiftUI's `.glassEffect` modifier wraps `NSGlassEffectView` on macOS 26.
NSGlassEffectView caches the sampled behind-window content and doesn't reliably
invalidate when other apps' windows move/minimize/close. Result: ghost-shadow
trails of dead apps showing through Rig. NSVisualEffectView is the canonical AppKit
primitive for live behind-window blur and gets compositor-driven invalidation.

### Don't stack glass on glass

Inner row hover/selected backgrounds are simple tinted `RoundedRectangle` fills,
not `.glassEffect`. Apple's docs explicitly say glass should not be stacked on
glass. We tried it; the result is "intense hideous blur" — the inner glass
compounds with the visual-effect background.

## Asset rendering

### SVG → PNG via `rsvg-convert` (librsvg)

The Codex asset is a PNG rendered via `rsvg-convert` (`brew install librsvg`),
not Xcode's vector preservation, not qlmanage, not Swift `NSImage`.

The source SVG uses `linearGradient gradientUnits="userSpaceOnUse"`. Each path we
tried fails differently:

- **qlmanage** silently caches a generic-thumbnail PNG with its own white
  rounded-square backdrop, regardless of input SVG. Different SVGs all produced
  byte-identical 159540-byte output. Cannot be cleared with `qlmanage -r cache`.
- **CoreSVG** (Swift `NSImage(contentsOf:)`, Xcode asset catalog vector path) logs
  `CoreSVG has logged an error` and produces a visibly mangled top-left corner.
- **rsvg-convert** correctly handles `userSpaceOnUse` gradients and produces a clean
  render.

The other harness SVGs (Pi, Claude, OpenCode) don't use such gradients and render
fine through Xcode's normal asset catalog path.

### Per-harness icon inset

`LauncherHarness.iconInset` (default 0.16) is per-harness because some SVGs have
natural margin built into their paths and some don't. OpenCode fills 100% of its
viewBox vertically, so it uses `iconInset = 0.24` to add visual breathing room
inside the circle.

## Launcher row layout

### Focus-anchored magnification

The dock-style magnification keeps the *focused* icon under the cursor. Other
implementations grow icons in place (cursor drifts off the icon). Ours computes:

1. Sizes per icon via Gaussian falloff over slot-distance from a fractional focus
   index (mapped from cursor position relative to the resting cluster bounds).
2. Cumulative positions in row-local coordinates.
3. A row shift such that the (interpolated) focus center sits at the cursor x,
   capped so the focus icon's right edge never overflows the panel.

The right-edge cap is *per-focus-icon*, not the rightmost icon in the row.
Capping by the rightmost would break anchoring for non-rightmost focus positions
(observed regression: hovering Pi makes Pi shoot far left).

### Resting cluster overlaps; hover spreads

Resting state uses negative HStack-equivalent spacing (`restingSpacing = -14`)
for an overlapping participant-stack look. Hover spreads to `activeSpacing = +6`.
The `ForEach` in the ZStack iterates `.reversed()` so the leftmost icon paints on
top in the overlap.

## What we explicitly don't do

- **Don't fight Ghostty's "new windows inherit fullscreen state" behavior.** If
  the user's existing Ghostty windows are full-screen, new Rig-launched ones will
  be too. This is a Ghostty/macOS NSWindow behavior, not a Rig bug. A future
  workaround is `perform action "toggle_fullscreen"` after AX-detecting the
  fullscreen state; deferred.
- **Don't try to embed Ghostty.** Spec is explicit: launcher and switcher only.
- **Don't add a polling reconciliation loop.** Removed for performance.

## Data model & persistence

One file: `~/Library/Application Support/Rig/config.json`. Everything user-configurable
(harnesses, projects, preferences) is in there. Versioned (`version: 1`), pretty-printed,
sorted keys.

`ConfigStore` (`Rig/Persistence/ConfigStore.swift`) is the single source of truth:

- Holds `@Published var config: RigConfig`. Views observe via
  `@EnvironmentObject store: ConfigStore`.
- Auto-saves on any mutation, **debounced 500ms** so dragging a slider produces one
  write, not hundreds.
- `firstRun()` seeds the file with built-in harness defaults on first launch.
- One-time migration: if `projects.json` exists from the old layout, its contents are
  folded into `config.json` and the old file is deleted. `sessions.json` is deleted
  unconditionally — sessions are no longer persisted.

`Harness` uses `HarnessIcon` (enum: `.builtin(name)` / `.file(URL)`) so user-supplied
SVGs slot in later without a model change. `HexColor` is a `Codable`-friendly string
wrapper that bridges to `SwiftUI.Color` (SwiftUI's `Color` is not Codable).

`GhosttySession` is **runtime-only** — not Codable, not persisted. Each Rig launch
starts with an empty session list. The struct stores `harnessID` and `projectID`
fields that future "session restore from intent" features can use.

## Useful files

- `SPEC.md` — original product spec.
- `AGENT_NOTES.md` — this file.
- `harness-icons/` — source SVGs for the launcher harnesses.
- `truck-front-svgrepo-com.svg` — source for the Truck app icon and empty-state image.

## Build/run

```sh
xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build build
open .build/Build/Products/Debug/Rig.app
```

Clear persisted state during development:

```sh
rm -f "$HOME/Library/Application Support/Rig/config.json"
```
