# Holoscape command palette pattern from Ghostty

Status: read-only spike for card #5931.

## Scope

This spike reads Ghostty's macOS command palette implementation in `~/projects/github-repos/ghostty/macos/Sources/Features/Command Palette/` and the adjacent terminal-controller/action integration points.

The goal is to capture patterns Holoscape can reuse later without adding another AI/product surface before core terminal reliability is finished.

## Ghostty module shape

Ghostty splits the palette into two layers:

1. **Generic palette UI** — `CommandPalette.swift` defines `CommandOption`, `CommandPaletteView`, query handling, keyboard navigation, row rendering, highlighting, and fuzzy-ish filtering.
2. **Terminal-specific option source** — `TerminalCommandPalette.swift` builds Ghostty terminal commands, update actions, and jump-to-terminal commands, then forwards selected actions back to the terminal controller.

This is the right seam. The generic palette is reusable UI; the terminal adapter decides what commands exist and how actions execute.

## Generic command option model

`CommandOption` is an immutable UI/action descriptor:

- title;
- optional subtitle and description;
- shortcut symbols;
- leading SF Symbol icon;
- leading color;
- badge text;
- emphasis flag;
- stable sort key;
- closure to execute on selection.

It is identified by a generated `UUID`, and equality/hash use that id. The action is not encoded or introspected by the palette.

Holoscape should not copy the closure shape directly for plugin commands. Core-local menu commands can use closures, but plugin/external commands need explicit command descriptors and routed actions like the existing plugin command router.

## Query and ranking behavior

The palette keeps raw query text in local state and trims it for matching. If the query is empty, all options display in provided order. If the query is non-empty, options are filtered and ranked by `CommandOptionMatch`:

1. color-name match score against `leadingColor`;
2. title match;
3. subtitle match;
4. description match.

String matching first tries case-insensitive substring search. If that fails, it falls back to initials matching, e.g. a query can match the first letters of words.

Important UX detail: when the user starts typing, the first match becomes selected. When the query is cleared, an auto-selected first row is cleared back to no explicit selection.

## Keyboard and focus behavior

`CommandPaletteQuery` owns keyboard behavior:

- Escape exits;
- Return submits selected action;
- Up/down arrows move selection;
- Ctrl-P/Ctrl-N also move selection;
- losing text-field focus exits the palette;
- focus is assigned asynchronously on appear to avoid an AppKit/SwiftUI timing issue.

`TerminalCommandPaletteView` handles restoration:

- the palette is shown as an overlay above the active surface;
- when it disappears, focus is returned to the original `SurfaceView` on the main queue;
- a `ResponderChainInjector` links the surface into the responder chain while the palette is open;
- terminal mouse handling checks `commandPaletteIsShowing` and avoids treating palette clicks as terminal focus/click events.

Ghostty also explicitly resigns the focused surface when opening the palette from certain title-editor states, because otherwise the terminal can consume shortcuts meant for the palette.

For Holoscape, this focus choreography is the biggest lesson. A command palette is only daily-driver quality if typing into the palette never leaks into the terminal and closing it reliably restores terminal focus.

## Terminal command sources

`TerminalCommandPaletteView.commandOptions` combines three families:

1. **Update options** — install/restart or cancel/skip update, emphasized and shown first.
2. **Jump options** — one `Focus: <title>` command per terminal surface across all terminal controllers/windows.
3. **Configured terminal commands** — commands from Ghostty config's `commandPaletteEntries`, filtered to supported entries and annotated with configured keyboard shortcuts.

The non-update commands are sorted with a terminal-specific comparator. It replaces `:` with a tab-like character before localized case-insensitive compare so category prefixes sort together, then uses the option sort key for stable ties.

Selecting a configured terminal command calls `onAction(c.action)`, and the terminal controller applies it to the active surface through `ghostty_surface_binding_action(...)`. Selecting a jump command posts a `ghosttyPresentTerminal` notification for the target surface.

## Event integration

The palette is toggled through the same action system as other terminal actions:

- Ghostty's action bridge receives `toggle_command_palette` against a surface target.
- It resolves the surface to a `SurfaceView`.
- It posts `.ghosttyCommandPaletteDidToggle` with that surface.
- `BaseTerminalController` only responds if its `surfaceTree` owns the surface.
- `toggleCommandPalette` flips `commandPaletteIsShowing`.
- `TerminalView` observes that state and overlays `TerminalCommandPaletteView` against the last focused surface.

This preserves a clean direction of ownership: command/action layer emits intent, controller owns presentation state, SwiftUI renders, and selected actions route back through the controller.

## What Holoscape should copy

### 1. Start with a command registry, not a palette view

Holoscape should define command descriptors first:

- stable id / namespace;
- title and optional subtitle/description;
- category;
- optional key equivalent display;
- availability predicate based on current channel/pane/app context;
- source (`core`, `plugin:<id>`, maybe `debug`);
- explicit action payload routed through a command executor.

The UI should consume descriptors. This keeps plugin commands removable and prevents the command palette from becoming a hidden integration dependency.

### 2. Keep plugin commands declarative

Ghostty's options hold closures. Holoscape plugin commands should not. The Project Tracker plugin work already uses namespaced command descriptors and a router; the command palette should present those descriptors and invoke the same router.

If a plugin is disabled, unavailable, or misconfigured, its commands disappear or show plugin-scoped unavailable state. Core terminal startup must not depend on plugin command loading.

### 3. Treat jump-to-channel as a core command family

Ghostty's jump options are a practical daily-driver win. Holoscape should eventually expose commands like:

- focus channel/tab;
- focus pane if split panes exist;
- reopen/attach stale broker-backed session;
- clear persistent channel state when safe;
- open setup diagnostics;
- open plugin-provided board/task URLs when the plugin is enabled.

These should reflect persistent channel state, not transient banners.

### 4. Test focus safety before visual polish

Before a Holoscape palette ships, add deterministic tests or UI smoke coverage for:

- opening palette does not send typed query text to the terminal;
- Escape closes and restores terminal focus;
- Return executes exactly one selected command;
- disabled plugin commands are absent/unexecutable;
- active-channel commands target the current channel/pane, not a stale prior one;
- palette clicks are not interpreted as terminal mouse input.

This matches the tank-backend rule: command UI must not destabilize terminal input.

### 5. Use simple matching first

Ghostty's substring + initials matching is enough for a first Holoscape slice. Avoid importing a heavy fuzzy engine until the command registry is stable. Ranking by title/subtitle/description/source priority is more important than fancy matching.

## Holoscape-specific cautions

- **Do not hardwire Project Tracker into the palette.** It should appear only through the optional plugin command descriptors.
- **Do not let palette actions bypass existing command routers.** The palette is a presentation surface, not a side-effect backdoor.
- **Do not couple palette availability to skins.** Skins can style the palette later, but the command registry and execution must work with skins off.
- **Do not route command execution through terminal text unless the command really is terminal input.** App/session commands should call typed command handlers, not paste strings into a PTY.
- **Do not add command breadth before focus/input correctness is proven.** A command palette that occasionally leaks keystrokes to a shell is worse than no palette.

## Suggested future implementation cards

1. **Define a core command descriptor registry.** Include source namespace, availability, display metadata, and typed action payloads.
2. **Expose existing core actions through the registry.** Start with focus channel, new shell/agent channel, setup diagnostics, clear scrollback tail, and plugin command descriptors already available through `PluginManager`.
3. **Build a minimal command palette UI.** Query field, ranked list, keyboard navigation, submit/escape, focus restoration; no skins required.
4. **Add input/focus regression coverage.** Verify palette typing never reaches the active terminal and closing restores focus.
5. **Add plugin command presentation.** Show Project Tracker commands only when the first-party plugin is enabled/ready, and execute only through the existing plugin command router.

## Source map

- `CommandPalette.swift` — generic option model, query field, keyboard events, filtering/ranking, rows, shortcut display.
- `TerminalCommandPalette.swift` — Ghostty terminal adapter: update commands, jump commands, configured command entries, focus restoration.
- `TerminalView.swift` — overlays `TerminalCommandPaletteView` against the last focused surface.
- `BaseTerminalController.swift` — owns `commandPaletteIsShowing`, handles toggle notifications, returns focus, executes selected terminal actions.
- `Ghostty.App.swift` — action bridge that turns `toggle_command_palette` into a surface-scoped notification.
- `SurfaceView_AppKit.swift` — guards terminal mouse/focus handling while the palette is visible.
