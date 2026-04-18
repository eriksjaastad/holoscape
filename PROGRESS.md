# Holoscape — Session Progress (2026-04-17 → 04-18 overnight)

## Start here tomorrow

Chrome skinning Task Groups 1–9 are complete. Next work should be:

1. **Task Group 13 (reference skin)** — ship an actual skin manifest with colors/images/fonts. This is the "first visible graphics" moment. `MainWindowController.applySkin(_:)` is the entry point — it takes `[SurfaceKey: SkinContext.ResolvedSurface]?` and re-injects into all chrome views.
2. **Task Group 10 (checkpoint)** — regression verify: build with no skin loaded, confirm identical look to pre-migration.
3. **Task Group 11 (hot reload)** — FSEventStream watcher on `~/.holoscape/skins/`, skin-picker in Appearance Settings, `.skinDidChange` wiring.
4. **Task Group 12 (Reader Mode)** — separate NSPanel.

## What shipped this overnight session

### 11 PRs merged

| PR | Scope |
|----|-------|
| #98 | Tabs-in-titlebar (Warp-style — recovered ~32pt of vertical real estate) |
| #99 | 8.1 + 8.3 — image loading with two-layer sandbox (string gate + symlink resolution) |
| #100 | 8.2 — ninepatch sidecar loading |
| #101 | 8.4 — font registration with `CTFontManagerRegisterFontsForURL`, process scope, symmetric drain |
| #102 | 8.5 — backing-scale parameter on `SkinContext.applyFill` |
| #103 | 9.1 — `TabBarView` → SkinContext |
| #104 | 9.3/9.4/9.6 — `InputBoxView`, `SessionLauncherView`, `SplitPaneView` → SkinContext |
| #105 | 9.2 — `SidebarView` + `SidebarTabEntry` → SkinContext (base fills) |
| #106 | 9.7/9.8 — window.background + `applySkin(_:)` entry point |
| #107 | 9.5 — `TerminalContainerView` **deleted** (dead code since April 5) |
| #108 | Option B — per-entry `ReactiveUniformSnapshot` on `SidebarTabEntry`, finishes the 8 deferred notification/indicator colors via state variants |

460 tests green (up from 400 at session start).

## Architectural decisions made tonight

1. **Tab bar lives in the titlebar band permanently.** `titleVisibility = .hidden` + `.fullSizeContentView` style mask. Tab bar pinned to `contentView.topAnchor` with 80pt leading inset for traffic lights. Always visible regardless of sidebar state.
2. **Path sandboxing is two-layer.** `validateAssetPath` catches `..` / absolute / `http(s)://` / `file://`. `assertPathResolvesInside` follows symlinks and blocks any resolved path that escapes the skin directory. Belt-and-suspenders — neither alone is sufficient.
3. **Font deregistration must match exactly what was registered.** `SkinFontBundle.registeredURLs` is the mandatory input to `unregisterFonts`. A CGFont-decode failure after a successful register triggers immediate rollback; rollback failures log loudly because the font has leaked into process scope.
4. **`MainWindowController.applySkin(_:)` does NOT post `.skinDidChange`.** Direct property assignments to the 5 chrome view slots already trigger each view's `didSet` → `refreshFromSkin`. Posting the notification on top would fire every repaint twice. Callers who need observers outside the controller post it themselves.
5. **Per-entry `ReactiveUniformSnapshot` over shared snapshot** for sidebar rows. Each `SidebarTabEntry` owns its own snapshot; `applyConfigure` writes `channelUnread`, `notificationKind`, `channelConnectionState`; state variants on `sidebarRowNormal` / `sidebarRowIndicator` resolve per-row. Two rows with different unread flags resolve to different colors at the same instant — impossible with a shared snapshot.
6. **`SkinContext.currentState(for: with snapshot:)` override.** Let callers resolve state variants against a specific snapshot instead of the context's shared one. Makes per-entry state possible without context proliferation.
7. **`sidebarRowIndicator` base fill is systemGreen (active), not clear.** An unmatched variant stays visible as the "active" color rather than silently going invisible. Bugs surface rather than hide.
8. **`SkinContext.builtInDefaults` now seeds state variants** on `sidebarRowNormal` (unread / idle / permission) and `sidebarRowIndicator` (connecting / disconnected). The skinned path reproduces the pre-skinning colors in hex; `SidebarTabEntry` also retains `fallback*` helpers for standalone-render paths. A parity test guards against drift.

## Assets / data-model extension points

- `SurfaceKey.terminalContainerPadding` stays in the enum (spec-level). No view paints it today — the terminal hierarchy routes through `SplitPaneView` + `MetalCompositor`. A future terminal-wrapping view can pick it up without a spec change.
- `SurfaceKey.windowTitleBar` deferred. The tab bar covers the titlebar band via `tabBar.container`. A dedicated title-bar accessory view would honor this surface.

## Outstanding architectural dependencies

- **Task 13 reference skin** — requires skin loader that converts a `SkinDefinition` manifest → `[SurfaceKey: ResolvedSurface]` map for `applySkin`. `SkinContext.convert(_:for:imageCache:)` already exists.
- **Task 11 hot reload** — FSEventStream + SkinDidChange + AppearanceSettings skin picker integration.
- **XCUITests on Mac Mini** — still blocked on Xcode-project sync (#5988).

## Clean working tree

- No uncommitted changes.
- No open PRs.
- No stale branches.
- `claude-specs/chrome-skinning/tasks.md` unchecked boxes still reflect "not done" even for Tasks 1–9; the `[ ]` markers in the file were never mechanically flipped. A PR that walks the tasks file and checks the completed ones would be a small tidy-up next session.

## Today's session summary (numbers)

- 11 PRs merged in one session.
- +60 tests (400 → 460), all green.
- 1 dead class deleted (`TerminalContainerView`).
- 1 architectural fix that finished the 8 deferred sidebar state colors rather than leaving them as TODO (Option B per-entry snapshot).
- 0 code-reviewer FAILs shipped — every PR passed local code review (several required iterations to get there).
