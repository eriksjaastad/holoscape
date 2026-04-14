# DIRECTION.md — Holoscape

## Goal
Native macOS terminal that replaces iTerm/Warp with channel-based management of AI agent conversations, local shells, and remote connections. Channels isolate auth, display role identity, and prevent mixed-up agent messages through clear visual distinction and unread indicators.

## Type: Milestone
A sprint-based project with defined version phases (V1 shipped, V2 shipped, V3 in progress) building toward full feature completion, then ongoing maintenance and refinement.

## North Star
Erik stops mixing up agent windows — every connection is visually distinct, identity is unambiguous, and text input works like a normal text editor.

## Current Focus
- V3 features: desktop notifications for unread channels, window splitting (side-by-side panes), bridge channel (broadcast to all agents), tab pinning, search across scrollback
- Infrastructure: bug report API endpoint, crash detection on launch
- Polish: keyboard shortcuts (Cmd+1-9), color theme presets

## Future
- V3 completion: Winamp-style skin engine, full layout customization
- V4: plugin/extension model, scriptable automation, multi-window support
