# Holoscape — Session Progress (2026-04-19, late afternoon)

## Today in numbers

Six PRs merged, five cards closed, three Amplify spec tasks flipped, Checkpoint 6 annotated. 729 tests green. Four-day shape blocker cleared.

| PR    | Title                                                              | Card  |
|-------|--------------------------------------------------------------------|-------|
| #134  | shaped-window reconstruction double-release                        | #6036 |
| #135  | content-view repaint after reconstruction                          | #6038 |
| #136  | polygon scaling + fixed-size + keyable borderless + drag overlay   | #6037 |
| #137  | malformed-skin banner                                              | 21.2  |
| #138  | logging audit + parent spec link                                   | 21.3 + 21.5 |
| #139  | wire shared AnimationEngine into app object graph                  | #6027 |

## The shape story, end-to-end

`HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS=1` + `AmplifyDemo` now does what Winamp did in 1998:

- Cut-corner octagon window (polygon mask fits the content view exactly at 1000×700)
- Terminal accepts keystrokes (`ShapedBorderlessWindow` overrides `canBecomeKey`)
- 20pt invisible drag strip at the top — drag works Winamp-title-bar-style (`WindowDragOverlay` on top of all chrome, delegates `performDrag` on mouseDown)
- Window is fixed-size — drag the edges, nothing happens. Matches the Winamp cultural model skin authors expect
- Switch back to Default → window becomes titled + resizable again, min 400×300

Code highlights if the next agent needs to navigate:

- `Sources/Holoscape/Controllers/ShapedWindowController.swift:1-20` — `ShapedBorderlessWindow` subclass; `canBecomeKey` / `canBecomeMain` override
- `Sources/Holoscape/Controllers/ShapedWindowController.swift:~150` — `scale(polygons:from:to:)` pure helper + `ResolvedWindowShape.nominalSize`
- `Sources/Holoscape/Controllers/MainWindowController.swift:~880` — `applyWindowShape` scales polygons to live content bounds, locks `contentMinSize == contentMaxSize`, strips `.resizable`
- `Sources/Holoscape/Controllers/MainWindowController.swift:~1280` — `windowDidResizeForShape` observer rebuilds mask + sampler + tracker on resize
- `Sources/Holoscape/Views/ShapedContentView.swift:1-40` — `WindowDragOverlay` (drag strip), invisible, hit-test isolates itself
- `Sources/Holoscape/Views/SkinWarningBanner.swift` — amber, 40pt, pinned to top; 5-second hold; reduce-motion path

## What's left on Amplify

From `claude-specs/amplify/tasks.md`:

- **Task 19.2** — `HoloscapeClassic` skin. Blocked on Erik sourcing art.
- **Task 21.6*** — hot-reload `.wamp` integration test. Optional; deferred to Mac-Mini dogfood per the rationale in `WampHotReloadTests.swift` (FSEvents round-trips interact badly with accumulated test-suite state; `startWatching` + `stopWatching` invariants are already pinned).
- **Task 21.9*** — accessibility override property test. Optional; requires refactoring `NSWorkspace.shared.accessibilityDisplayShould*` reads behind a protocol boundary before tests can control the prefs. Moderate scope.
- **Checkpoints 8, 10, 12, 14, 16, 18, 20, 22** — Mac-Mini dogfood steps. Must be run on the Mini.

## Working tree

- **On main** at `origin/main`.
- **No open PRs.** All six from today merged.
- **No stale branches.**
- **Untracked:** `tools/package_synthwave.sh` — case-insensitive FS duplicate of `Tools/package_synthwave.sh`, can be removed, low priority.

## Outstanding cards

Board for holoscape is essentially empty on the laptop side. Everything remaining is earmarked for Mac Mini dogfood or blocked on art.

## Next-session starting points

1. If Erik wants `HoloscapeClassic`: source the art, open a branch, author the `.wamp` manifest, `swift test`, PR.
2. If Erik wants Mac-Mini dogfood: `ssh eriksjaastad@Eriks-Mac-mini.local`, checkout main, `swift test`, bundle, run each Checkpoint from `claude-specs/amplify/tasks.md`.
3. If Erik wants to polish Amplify Demo visuals: tone down `sidebar.row.selected` magenta, replace the programmatic refresh-button sprite sheet with real art.
4. If Erik wants optional Task 21.9: refactor `NSWorkspace` accessibility-pref reads behind a protocol boundary first, then write the property tests.
