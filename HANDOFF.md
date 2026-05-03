# Rig Handoff

## What This Project Is

Rig is a native macOS sidecar app for Ghostty. It does not embed a terminal and does not modify Ghostty. Its job is to open Ghostty sessions, keep a small vertical list of the sessions it created, and focus the right Ghostty window/tab/terminal when the user clicks a row.

The intended MVP is intentionally simple:

- A small detached macOS window.
- A Liquid Glass-style surface.
- A single plus button.
- Auto-named sessions: `Session 1`, `Session 2`, etc.
- No custom naming or setup input.
- Single-click a row to focus that managed Ghostty session.

Longer term, the user would like this to feel like a high-quality macOS 26 app and possibly become a single integrated sidebar experience. For now, Ghostty should remain a normal independent app window.

## Current State

The project builds and the unit tests pass, but the runtime behavior has been buggy in real use. Treat the current implementation as a prototype, not a stable base.

Verified recently with:

```sh
xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build build
xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-test test
```

Recent result: 10 tests passed, 1 Ghostty integration test skipped.

Run the locally built app with:

```sh
open .build/Build/Products/Debug/Rig.app
```

Clear persisted development sessions with:

```sh
rm -f "$HOME/Library/Application Support/Rig/sessions.json"
```

The user explicitly prefers clearing development sessions while the app is unstable. That reset has been run manually, but there is not yet an automatic DEBUG-only reset-on-launch path.

## Repo Map

- `Rig/RigApp.swift`: SwiftUI app entry point, menu commands, hidden-titlebar window style.
- `Rig/AppDelegate.swift`: macOS app delegate, regular activation policy, keeps app alive after closing last window.
- `Rig/Views/ContentView.swift`: main glass window, toolbar, session list, AppKit window styling bridge.
- `Rig/Views/SessionRowView.swift`: row UI, selected/hover glass effects, status dot.
- `Rig/ViewModels/SessionListViewModel.swift`: session creation, focus, sync, selection, persistence orchestration.
- `Rig/Controllers/GhosttyController.swift`: protocol for Ghostty operations.
- `Rig/Controllers/AppleScriptGhosttyController.swift`: actual Ghostty AppleScript bridge.
- `Rig/Models/GhosttySession.swift`: persisted app session model.
- `Rig/Models/GhosttyState.swift`: decoded Ghostty state snapshot and resolution helpers.
- `Rig/Persistence/SessionStore.swift`: JSON storage under `~/Library/Application Support/Rig/sessions.json`.
- `RigTests/RigTests.swift`: unit tests and opt-in real Ghostty integration test.
- `SPEC.md`: original product spec. Useful context, but some parts are broader than the current MVP.

## Architecture

The app is SwiftUI with a small AppKit bridge for window behavior.

At a high level:

1. `ContentView` renders the window and list.
2. The plus button calls `SessionListViewModel.createSession()`.
3. The view model calls `GhosttyControlling.createWindow(workingDirectory:)`.
4. `AppleScriptGhosttyController` uses `NSAppleScript` to tell Ghostty to create and focus a new window.
5. The returned Ghostty IDs are persisted in `GhosttySession`.
6. Row clicks call `SessionListViewModel.requestFocus(_:)`.
7. The view model calls `focusTerminal(windowId:tabId:terminalId:)`.
8. Polling sync runs every 10 seconds with `queryState()`.

The current identity strategy is:

```text
window id + tab id + terminal id
```

Focus was recently tightened to require the exact stored tuple. Earlier code allowed a fallback by terminal ID alone, which was unsafe around unmanaged Ghostty windows.

## Ghostty Automation

The current bridge uses `NSAppleScript`, not `osascript` or Accessibility APIs.

Implemented operations:

- `queryState()`: snapshots Ghostty frontmost state plus windows, tabs, terminals, names, IDs, selected tab, focused terminal, and working directories.
- `createWindow(workingDirectory:)`: snapshots existing Ghostty window/terminal IDs, asks Ghostty for a new window with an initial working directory, then tries to identify the new surface.
- `focusTerminal(windowId:tabId:terminalId:)`: activates Ghostty, finds the exact managed tuple, selects the tab, focuses the terminal.
- `closeTerminal(id:)`: finds a terminal by ID and closes it.

The scripts manually build JSON strings in AppleScript and decode them in Swift. This works in tests with fakes, but the real Ghostty AppleScript object model has been brittle in practice.

## UI And Windowing

The app is trying to use macOS 26 Liquid Glass:

- `GlassEffectContainer`
- `.glassEffect(...)`
- `.buttonStyle(.glass)`
- `.windowStyle(.hiddenTitleBar)`
- transparent full-size content window

`ContentView` also has an `NSViewRepresentable` called `WindowConfigurator`. It configures:

- hidden title
- transparent titlebar
- full-size content view
- clear background
- floating window level
- all-spaces collection behavior
- custom traffic-light positioning

This AppKit bridge has been a source of warnings and visual glitches. The latest change avoids mutating traffic-light frames directly inside the active AppKit layout pass and defers that work to the next main-loop tick.

## Known Runtime Problems

### 1. First created session sometimes focuses an unmanaged Ghostty window

Observed behavior: creating the first Rig session sometimes focused an existing Ghostty session, including the active chat terminal, instead of the newly created Ghostty surface.

Likely causes:

- The original creation logic trusted the object returned by `new window with configuration cfg`.
- The original focus logic could fall back to terminal ID alone.
- Existing unmanaged Ghostty windows make positional or “frontmost” assumptions unsafe.

Recent mitigation:

- `createWindow` now snapshots existing window and terminal IDs before creation.
- It only accepts a candidate whose window ID and terminal ID were not present before creation.
- `focusTerminal` now requires exact stored window/tab/terminal tuple.

This still needs real-world validation.

### 2. Invalid index AppleScript crash/error

Observed error:

```text
Ghostty got an error: Can’t get item 2 of every terminal of item 1 of every tab of item 11 of every window. Invalid index.
```

This strongly suggests the AppleScript is holding or traversing object specifiers that become invalid while Ghostty changes windows/tabs/terminals, or that Ghostty’s scripting bridge returns collection specifiers that are not stable under nested `repeat` traversal.

High-value next step:

- Rewrite the Ghostty scripts to avoid deep chained object specifiers where possible.
- Capture object lists into plain AppleScript lists before nested traversal.
- Add real integration tests that create multiple unmanaged Ghostty windows before creating/focusing Rig sessions.
- Consider using Ghostty CLI or a more stable automation surface if one exists.

### 3. Session switching lag

The user observed 5 to 10 seconds of lag when switching sessions, including from the context menu.

Likely causes:

- AppleScript execution against Ghostty is synchronous and can block.
- `NSAppleScript` cancellation is cooperative only at our Swift task boundaries. Once the script is executing, cancelling the Swift `Task` does not necessarily stop Ghostty/AppleScript work.
- The focus script activates Ghostty and enumerates windows/tabs/terminals.

Recent mitigation:

- UI row activation is now a full-width plain `Button`.
- `requestFocus(_:)` keeps only one pending focus task and cancels stale focus requests.

This is not enough if the underlying `NSAppleScript` call is already blocking. The next developer should instrument script timings and consider serializing all Ghostty automation through one queue with clear “latest request wins” behavior.

### 4. Click behavior was confusing

Observed behavior:

- User wanted single-click switching.
- Some click sequences felt like single-clicking one row, then another row triggered the other as if it were a double-click.
- Weird clicking could eventually lead to crashy behavior.

Recent mitigation:

- Rows are now actual full-width `Button`s instead of `onTapGesture`.
- Context menu focus also goes through `requestFocus(_:)`.

Still validate with rapid clicking and context-menu use.

### 5. Liquid Glass / chrome issues

Observed issues:

- The titlebar/traffic-light strip originally sat above the glass instead of inside it.
- The glass shell initially stopped growing at wider widths.
- Bottom corners showed radius/border mismatch.

Recent mitigations:

- Added `.windowStyle(.hiddenTitleBar)`.
- Root glass now fills a rectangular full-window surface so the native window radius clips the outer edge.
- Traffic lights are manually repositioned into the glass area.

This is still fragile because native traffic-light positioning is AppKit-owned. Reconsider whether the app should use native titlebar placement with less manual adjustment.

### 6. Xcode runtime warnings

User saw:

```text
It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out.
FSFindFolder failed with error=-43
FSFindFolder failed with error=-43
```

Recent mitigations:

- Removed direct window styling from the active `layout()` body; it now schedules async.
- `SessionStore` now uses `~/Library/Application Support/Rig` directly and creates the directory before load.

I launched the built app briefly from the command line and saw no stderr, but that does not fully prove the Xcode console warnings are gone.

## Testing

Unit tests currently cover:

- Session store round-trip.
- Missing session store starts empty.
- Auto-naming sessions.
- Sync marks missing terminals.
- Removal behavior.
- Sync refreshes moved window/tab IDs.
- Ambiguous terminal ID sync behavior.
- Focus does not run full state query.
- Focus requires exact stored window/tab/terminal tuple.

There is an opt-in real Ghostty integration test:

```sh
RUN_GHOSTTY_INTEGRATION=1 xcodebuild -project Rig.xcodeproj -scheme Rig -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-test test
```

This integration test creates, focuses, queries, and attempts to close a real Ghostty window. It should be expanded significantly before trusting this app.

## Development Notes

This is a brand-new greenfield repo. At the time of handoff, most files may still appear untracked depending on the local git state. Do not assume the git status is clean.

The project targets modern macOS and Swift:

- Swift 6.
- macOS 26 SDK.
- Xcode build commands above are known to work on the current machine.

The app has Apple Events usage text in `Info.plist` and an automation entitlement in `Rig.entitlements`. If automation permissions fail, macOS privacy prompts or TCC state may be involved.

## Recommended Next Steps

1. Add a DEBUG-only setting or launch path to clear `SessionStore` on startup while the prototype is unstable.
2. Run the opt-in Ghostty integration test with multiple unmanaged Ghostty windows already open.
3. Instrument every AppleScript call with start/end timing and log the operation name.
4. Rewrite `AppleScriptGhosttyController` scripts to reduce nested object-specifier traversal.
5. Decide whether manual traffic-light positioning is worth keeping. It improves the glass look but risks AppKit layout warnings.
6. Add a visible lightweight “focusing” state to rows so users can tell when AppleScript is still working.
7. Consider a dedicated `GhosttyAutomationQueue` actor that serializes all Ghostty interactions and drops stale focus requests before starting new scripts.
8. Keep the MVP narrow until focus/create reliability is solid. Avoid adding custom naming, search, or richer controls until session identity is trustworthy.

## Current Product Intent In One Sentence

Rig should be a small, elegant macOS Liquid Glass sidecar that opens auto-named Ghostty sessions and lets the user single-click between only the Ghostty sessions Rig actually manages.
