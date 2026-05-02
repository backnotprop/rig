Here’s a handoff-ready spec.

````markdown
# Ghostty Vertical Session Switcher — macOS Sidecar App Spec

## Goal

Build a macOS sidecar app that provides a vertical tab/session list for Ghostty without modifying Ghostty.

The app should launch Ghostty sessions, track them, display them in a vertical sidebar, and focus the correct Ghostty window/tab/terminal when a user clicks an item.

Ghostty remains the actual terminal emulator. This app is only a launcher, index, and switcher.

## Key dependency

Target Ghostty 1.3.0+ on macOS because Ghostty added AppleScript support for inspecting and controlling windows, tabs, splits, and terminals. AppleScript support can query/control Ghostty’s application → windows → tabs → terminals object model. It is described as suitable for launcher workflows and custom automation. :contentReference[oaicite:0]{index=0}

## Non-goals

- Do not fork Ghostty.
- Do not embed Ghostty’s live window inside this app.
- Do not implement a terminal emulator.
- Do not rely only on window titles for identity.
- Do not require tmux.

## Product behavior

The app shows a narrow vertical sidebar with a list of Ghostty sessions.

Each session item shows:

- Friendly name
- Current working directory
- Status: active, running, missing, closed
- Optional project icon/color
- Optional last focused timestamp

Clicking a session:

1. Activates Ghostty.
2. Focuses the matching Ghostty window.
3. Selects the matching Ghostty tab if applicable.
4. Optionally focuses the matching terminal/split if AppleScript supports it reliably.

## Architecture

Use a native macOS app.

Recommended implementation:

- Swift + SwiftUI for UI
- AppleScript/JXA bridge via `NSAppleScript` or `osascript`
- Accessibility permissions for fallback focus/window detection
- Persistent storage via SQLite or JSON file

## Core data model

```swift
struct GhosttySession: Codable, Identifiable {
    let id: UUID

    var label: String
    var cwd: String?
    var command: String?
    var createdAt: Date
    var lastFocusedAt: Date?

    var ghosttyWindowId: Int?
    var ghosttyTabId: Int?
    var ghosttyTerminalId: Int?

    var windowTitle: String?
    var tabTitle: String?
    var terminalName: String?

    var status: SessionStatus
}

enum SessionStatus: String, Codable {
    case running
    case active
    case missing
    case closed
}
````

## Identity strategy

Primary identity should be Ghostty’s own AppleScript object IDs:

```text
window id + tab id + terminal id
```

Fallback identity chain:

```text
1. window_id + tab_id + terminal_id
2. cwd
3. title/name
4. launch timestamp proximity
5. user manual relink
```

Important: the app should prefer sessions it created itself. User-created Ghostty windows may be imported, but they are less reliable.

## Session creation flow

When the user clicks “New Session”:

1. User selects:

   * label
   * cwd
   * optional command
2. App launches Ghostty.
3. App waits briefly for Ghostty state to update.
4. App queries Ghostty windows/tabs/terminals via AppleScript.
5. App identifies the newly created terminal using:

   * cwd match
   * newest window/tab/terminal
   * title if available
6. App stores Ghostty IDs in `GhosttySession`.

Pseudo-flow:

```text
createSession(label, cwd, command):
  before = queryGhosttyState()
  launch Ghostty with cwd/command
  sleep 300-800ms
  after = queryGhosttyState()
  candidate = diff(after, before)
  store candidate.windowId/tabId/terminalId
```

## Launch behavior

Preferred launch command:

```bash
open -a Ghostty --args --working-directory "/path/to/project"
```

If Ghostty CLI supports a better direct launch API on the user’s installed version, use that.

For commands, launch shell with:

```bash
cd "/path/to/project" && exec $SHELL
```

or:

```bash
cd "/path/to/project" && <user command>
```

## AppleScript operations

Implement these operations behind a `GhosttyController` abstraction:

```swift
protocol GhosttyController {
    func queryState() throws -> GhosttyState
    func focus(session: GhosttySession) throws
    func launchSession(label: String, cwd: String?, command: String?) throws -> GhosttySession
    func close(session: GhosttySession) throws
}
```

### Query state

Return all Ghostty windows, tabs, and terminals.

Shape:

```json
{
  "windows": [
    {
      "id": 1,
      "name": "backend",
      "index": 1,
      "tabs": [
        {
          "id": 4,
          "name": "server",
          "selected": true,
          "terminals": [
            {
              "id": 9,
              "name": "server",
              "cwd": "/Users/me/code/backend"
            }
          ]
        }
      ]
    }
  ]
}
```

### Focus session

Pseudo AppleScript:

```applescript
tell application "Ghostty"
  activate
  set targetWindow to first window whose id is WINDOW_ID
  set index of targetWindow to 1
  set selected tab of targetWindow to first tab of targetWindow whose id is TAB_ID
end tell
```

If direct `selected tab` assignment is not supported exactly this way, Codex should inspect Ghostty’s AppleScript dictionary and adapt.

## UI

Main window:

```text
┌──────────────────────┐
│ + New Session        │
├──────────────────────┤
│ ● backend-api        │
│   ~/code/backend     │
│                      │
│   frontend-ui        │
│   ~/code/frontend    │
│                      │
│   infra              │
│   ~/code/infra       │
└──────────────────────┘
```

Features:

* Always-on-top optional
* Narrow width, resizable
* Search/filter
* Keyboard shortcuts:

  * Cmd+N: new session
  * Cmd+1..9: focus first nine sessions
  * Cmd+K: search
  * Enter: focus selected session
* Context menu:

  * Rename
  * Reveal cwd in Finder
  * Relaunch
  * Remove from sidebar
  * Close Ghostty session

## Sync behavior

Run a polling sync every 1–2 seconds.

On sync:

1. Query Ghostty state.
2. Mark missing sessions if their stored IDs no longer exist.
3. Mark active session if Ghostty frontmost window/tab matches.
4. Offer relink if a session is missing but cwd/title matches another terminal.

Do not assume Ghostty sends reliable events.

## Permissions

The app may need:

* Automation permission to control Ghostty.
* Accessibility permission for fallback focus/window detection.

On first launch, show onboarding explaining:

```text
This app needs permission to control Ghostty so it can switch sessions.
```

## Reliability rules

* Never identify sessions only by title.
* Store Ghostty IDs immediately after launching.
* Re-query before focusing.
* If IDs are stale, attempt fallback relink.
* If fallback is ambiguous, ask user to pick a matching Ghostty window.
* Treat Ghostty AppleScript API changes as possible because AppleScript support is relatively new/preview in Ghostty 1.3.0. ([Ghostty][1])

## MVP

1. Sidebar app launches Ghostty sessions.
2. Stores window/tab/terminal IDs.
3. Displays session list.
4. Clicking a session focuses Ghostty.
5. Polls Ghostty and marks missing sessions.
6. Supports rename/remove/relaunch.

## V2

* Import existing Ghostty windows.
* Drag reorder sessions.
* Project groups.
* Workspace folders.
* Session templates.
* Hotkey global launcher.
* Optional menu bar mode.
* Automatic cwd/title-based relinking.
* Visual indicators for active/running/missing.
* Restore all sessions on app launch.

## Acceptance criteria

* Creating 40 sessions from the app produces 40 sidebar entries.
* Clicking any entry focuses the correct Ghostty window/tab.
* Closing a Ghostty window marks the sidebar item as missing within 2 seconds.
* Relaunching a missing session creates a new Ghostty window and updates stored IDs.
* Renaming a sidebar item does not break identity.
* Duplicate cwd values are handled without ambiguity by using Ghostty object IDs.
* App continues working after Ghostty is quit and reopened, though previous sessions may require relaunch/relink.

## Open implementation questions for Codex

* Confirm exact Ghostty AppleScript syntax for:

  * enumerating windows/tabs/terminals
  * reading cwd/name/id
  * selecting a tab
  * focusing a terminal/split
* Confirm best Ghostty launch command for cwd on macOS.
* Decide whether to use `NSAppleScript`, `osascript`, or JavaScript for Automation.
* Decide whether Accessibility APIs are needed for active-window detection.

```
::contentReference[oaicite:2]{index=2}
```

[1]: https://ghostty.org/docs/install/release-notes/1-3-0?utm_source=chatgpt.com "1.3.0 - Release Notes"
