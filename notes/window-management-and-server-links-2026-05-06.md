**Scope**

This note captures the window-management, server-link, and native Split View work from the May 6, 2026 Rig prototype session. It is meant as a checkpoint for future agents so we do not rediscover the same macOS/Ghostty behavior from scratch.

**Stable Work**

- Added a window arrangement menu above the session list.
- Current stable arrangement modes are Cascade, Grid, Side by Side, and Fill Screen.
- Arrangement is scoped to Rig-managed Ghostty sessions, not every Ghostty window.
- The correct identity source is Ghostty's stable AppleScript window/terminal IDs. CGWindowIDs are useful for AX lookup but are not durable enough to be the source of truth.
- Rig keeps an in-memory `ManagedGhosttyWindowRegistry` of AX window handles keyed by Rig session ID. AX handles are fast but can go stale after close/recreate/fullscreen transitions, so Ghostty IDs remain the durable identity.
- Fullscreen arrangement works by setting `AXFullScreen = false`, waiting through macOS teardown, then applying AX position/size repeatedly while the window settles.
- Closing full-screen sessions requires exiting native fullscreen first; otherwise Ghostty/macOS can show confirmation or fail to close consistently.

**Server Detection**

- Added `PortMonitor` to detect local TCP listeners and show clickable URLs under session rows.
- The reliable attribution approach is working-directory matching:
  - Poll listening TCP ports.
  - Resolve each listener PID's cwd.
  - Attribute the listener to a session when the cwd is inside that session/project path.
- Process ancestry was not reliable because backgrounded servers launched by agent tooling can become reparented.
- Baseline-diff attribution was not reliable because servers may already be running before a Rig session is created.
- `SessionListViewModel` mirrors `PortMonitor.serversBySession` into its own published state so SwiftUI updates correctly.
- Dummy data mode exists through `RIG_DUMMY_DATA=1`, seeding fake sessions and server links for UI testing without running real dev servers.

**Stable URL Split**

- Clicking a detected URL opens it normally.
- The visible split icon opens the URL and arranges Ghostty on the left with the browser on the right on the current desktop Space.
- This is the stable path to keep exposed:
  - Resolve the managed Ghostty AX window.
  - Open the URL in the default browser.
  - Resolve the browser AX window.
  - Prepare both windows as normal windows.
  - Apply side-by-side frames.

**Native Fullscreen Split View Prototype**

- Native macOS Split View was prototyped but is hidden from the UI for now.
- The filled split icon was removed/commented out from `SessionRowView`.
- The implementation remains in `WindowArranger.openURLInNativeSplitView` as a TODO reference.
- The most successful recipe was:
  - First create a clean normal side-by-side pair.
  - Drive native Split View from Ghostty, not Chrome.
  - Use Ghostty's `Window > Full Screen Tile > Left of Screen`.
  - Then click the browser candidate on the right side of the Split View picker.
- Chrome-first native tiling was less reliable and sometimes looked identical to desktop tiling.
- Tahoe/macOS 26 has multiple tiling menu families:
  - Regular desktop tiling/move-resize.
  - Fullscreen native Split View under `Window > Full Screen Tile`.
- We specifically need the fullscreen tile menu for a real divider/new fullscreen Space.

**Why Native Split View Is Still Hidden**

- The Split View picker is not exposed as a clean public API.
- The prototype uses synthetic mouse clicks to choose the second window, which is inherently brittle.
- Exiting a session from native Split View back into a grid/cascade layout is also brittle:
  - macOS can restore or replace AX/CGWindow objects during Split View teardown.
  - Cached AX handles and CGWindowIDs may point at transient/dying window records.
  - A private Space move attempt using Hammerspoon-style SLS/CGS APIs made one Ghostty session appear to disappear, so that path was backed out.
- If revisited, treat native Split View as a separate prototype branch. Do not wire it into the main URL row until picker selection and teardown are reliable.

**Private Spaces Research**

- Hammerspoon's `hs.spaces` uses private SkyLight/SLS APIs such as:
  - `SLSCopySpacesForWindows`
  - `SLSMoveWindowsToManagedSpace`
  - `SLSSpaceSetCompatID`
  - `SLSSetWindowListWorkspace`
- On macOS 14.5+ Hammerspoon/Yabai-style compat-ID movement is needed for some Space moves.
- Important limitation from Hammerspoon's own notes: moving a window between Spaces only works cleanly for normal user Spaces. It does not solve moving a fullscreen/tiled app window directly out of a native fullscreen/Split View Space.
- Any future use of those APIs should happen only after the window has become a normal window again, and should be guarded so the target Space is a normal user desktop.

**Current Recommendation**

- Keep the stable desktop split exposed.
- Keep native fullscreen Split View commented out as TODO.
- If native Split View comes back:
  - Start from the Ghostty-first recipe above.
  - Add robust detection for the Split View picker state.
  - Reacquire Ghostty AX windows after fullscreen/Split View teardown before any layout.
  - Avoid moving windows to Spaces until the target and source are confirmed normal user Spaces.
