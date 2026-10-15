# HoloScape direction

## Goal

Build a native macOS terminal that can replace iTerm and Warp for daily work:
rock-solid local session ownership, clear channel identity, durable state, and
useful visual character without making AI integrations part of the terminal core.

## North star

Every connection is unambiguous, sessions survive ordinary UI lifecycle changes,
and terminal input/output remains correct under failure, retry, and relaunch.

## Shipped foundation

- Native AppKit terminal with SwiftTerm rendering.
- Broker-owned local shell and agent PTYs with detach/reattach and bounded
  disk-backed scrollback.
- Persistent tab truth and process-scoped agent status.
- Sidebar/top-tab navigation, pinning, flat split panes, native menus, session
  launcher, SSH, group chat, and current skin/chrome infrastructure.
- Loopback HTTP control API and separate `HoloscapeMCP` server executable.
- Optional, permissioned plugin seam with Project Tracker as a removable
  first-party plugin.

## Current priorities

1. Terminal/process correctness and crash resilience.
2. Truthful launch, restore, quit, persistence, and failure behavior.
3. Main-actor responsiveness and bounded broker transport work.
4. Daily-driver regression coverage for launch/restore/teardown, persistence
   failure, process cancellation, and app-hosted UI behavior.
5. Documentation and tooling that describe only current, executable paths.

## Future product work

- Complete remaining notification, bridge, output-search, and split-layout polish.
- Continue skin/chrome work without weakening terminal reliability or removing
  existing visual capabilities by assumption.
- Consider marketplace distribution, general scripting, or multi-window support
  only after the core daily-driver gate is stable.

Current architecture decisions live in `DECISIONS.md`; product behavior and
explicitly future scope live in `PRD.md`.
