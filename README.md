# Rig

Rig is a small macOS sidecar for Ghostty.

It gives engineers a fast way to create, focus, arrange, and track terminal sessions across projects and coding harnesses.

Rig is not a terminal emulator. It does not embed Ghostty. It controls real Ghostty windows through Ghostty AppleScript and macOS Accessibility APIs.

## Demo

https://github.com/user-attachments/assets/4eabc7a1-01ab-460b-bd5c-87b496cd4299

## What It Does

- Launch Ghostty sessions for configured harnesses
- Keep session windows reachable from a floating side panel
- Switch directly to a session's Space
- Arrange managed Ghostty windows as grid, cascade, side by side, or fill screen
- Detect local servers started from sessions and show clickable URLs
- Open a detected URL beside its Ghostty session on the current desktop

## Requirements

- macOS
- Ghostty
- Accessibility permission for window arrangement
- Automation permission to control Ghostty

## Development

```sh
./dev.sh
```

This builds, signs, and launches the local development app.

## Release

```sh
./release.sh
```

This builds the distributable macOS app.

## Notes

Rig keeps runtime session state in memory. Ghostty window IDs and Accessibility references are not durable across app or Ghostty restarts.
