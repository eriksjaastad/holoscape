# Amplify PRD

*The 2026 Winamp for Holoscape.*

Codename: **Amplify**
Status: Draft, 2026-04-19
Author: Claude (Opus 4.7) + Erik (product owner)
Parent spec: `docs/chrome-skinning-prd.md` (Tasks 1–13 merged in PRs #98–#115)
Kanban card: #6030 (holoscape project, High priority)

---

## 1) Overview

Amplify extends Holoscape's chrome-skinning system from "themeable chrome" (today: color, gradient, ninepatch fills per surface) to "Winamp-class skinning" — shaped windows, per-element sprite art with pressed/hover/normal states, skin-authored click-through and drag regions, custom typography consumed by chrome views, 3D-ish border/corner/shadow depth, and a distributable `.wamp` bundle format. The "2026 Winamp" — a macOS-native terminal whose skin can be as distinctive as any Winamp 2 skin from 1998.

## 2) Goals

- **Shaped windows.** Skins can declare non-rectangular window shapes via polygon regions or PNG alpha masks.
- **Per-element sprite art.** Every skinnable element (tab buttons, sidebar rows, input box, session launcher, reader panel chrome) can be a bitmap with state rows (normal / hover / pressed / active) that the chrome views slice and apply.
- **Click-through & drag regions.** Pixels outside the skin's declared visible region are click-through. Skin can declare explicit drag-handle regions so the user moves the window by grabbing skin-painted chrome, not a system title bar.
- **Chrome typography.** Skins ship a TTF (and/or optional bitmap font). Tab titles, sidebar labels, input prompt, status indicators, reader-panel header all render in it.
- **Border / corner / shadow depth.** Existing `BorderDescriptor` / `CornerDescriptor` / `ShadowDescriptor` model types get consumed by every chrome view so skins can add bevels, glows, shadows, and beveled corners.
- **`.wamp` bundle format.** Single-file ZIP-based distribution: versioned manifest, assets, regions, fonts. Drop-in install. Existing `HoloscapeSynthwave` reference skin gets ported to `.wamp` as proof.
- **Backward compatible.** Existing v2 manifests in `~/.holoscape/skins/<name>/skin.json` (directory layout) keep working without modification.
- **Hot reload stays fast.** Edit a `.wamp` in place (or a directory-layout skin), chrome updates within 200ms, no restart. Already true for directory layout; extend to `.wamp`.

## 3) Non-Goals

- **No plugin / scripting system.** Winamp's Maki language is out of scope. Skins are declarative manifests + assets, not code.
- **No visualizer DSL.** Winamp's AVS / Milkdrop visualization system is a different feature area. Holoscape has its own shader pipeline (separate); Amplify does not subsume it.
- **No multi-audio-window semantics.** No Equalizer, no Mini-browser, no Playlist editor. Holoscape is a terminal. Analogous components (Reader Mode panel, future status bar / command palette) are in scope.
- **No direct `.wsz` import from existing Winamp skins.** Nice-to-have for later; would require full Winamp bitmap-layout semantics (NUMBERS.BMP, TEXT.BMP, VISCOLOR.TXT) that don't map to Holoscape's surfaces. Possible follow-up card; not required.
- **No art commissioning.** This PRD specifies the engine. Art assets are Erik's track (hand-authored or commissioned or procedural).
- **No cross-platform work.** Native AppKit / Swift only. No SwiftUI port, no Catalyst, no Linux.
- **No per-window-group theming (Winamp docking).** Holoscape has one window; Reader panel is second. Those get themed. More-windowed futures (detachable tabs, floating palettes) are out of Amplify's scope.

## 4) Target Users

**Primary: Holoscape daily-driver users.** Erik and anyone else using Holoscape as their primary terminal. Selects a skin from the Appearance Settings picker, wants a visually distinctive environment that doesn't look like "generic dark mode + gradient."

**Secondary: Skin authors.** Designers or hobbyists who want to create and share Holoscape skins. They need:
- A documented `.wamp` format
- Sample skins to copy from (`HoloscapeSynthwave` ported + one intentionally-Winampy skin)
- Hot reload so they can iterate without restarts
- Clear failure modes (a malformed skin logs + falls back; doesn't brick the app)

**Tertiary: Tool builders.** Someone writing a Winamp-skin → Holoscape-skin converter, or a visual skin editor. Needs the `.wamp` format spec to be stable and documented.

## 5) Problem Statement

Mac Mini dogfood on 2026-04-18 of the `HoloscapeSynthwave` reference skin drew Erik's response: "nothing looks like what you'd call skinning, we're just coloring sections." The chrome-skinning system delivers themeable rectangles. It doesn't deliver the subjective "this is a skin" feeling — the Winamp 2-era experience of a program that's been visually transformed into something else.

Six specific gaps:
1. Every window is a rectangle. No shape authoring.
2. Buttons are colored boxes. No sprite art, no pressed states driven by skin.
3. No skin-authored hit testing. The window border and drag handle are system-provided.
4. Tab titles and sidebar labels render in system font regardless of skin.
5. Borders, corners, and shadows from the manifest are parsed but never applied by chrome views.
6. No distributable bundle. A user installs a skin by copying a directory into `~/.holoscape/skins/<name>/`; there's no `skin.wamp` double-click-to-install.

Amplify closes all six.

## 6) Core Concept

Amplify is the engine layer that turns the existing `SurfaceDescriptor` model from "chrome theme" into "chrome skin." Architectural posture: **additive, not replacement.** Existing v2 manifests keep working. New capabilities slot in as optional fields and new `SurfaceKey` cases.

**Key architectural moves:**

- **Shaped windows** use `NSWindow(styleMask: .borderless)` + `contentView.layer.mask` (CAShapeLayer driven by polygon regions, or a CALayer with an alpha-mask contents from a PNG). Regions are declared in the manifest analogous to Winamp's `region.txt` but JSON-formatted.
- **Sprite sheets** extend `FillDescriptor.image` with optional `sprite: { cols, rows, cellWidth, cellHeight, stateMap }` metadata. `SkinContext.applyFill` slices the relevant cell based on the element's current state. The `SurfaceKey` catalog grows to include explicit per-state keys where a sprite row is the natural expression (e.g., a tab button's normal/hover/pressed/active).
- **Click-through + drag regions** are layered on the shaped-window foundation. The same regions that define visibility define hit-testing — pixels outside a region don't receive mouse events. Drag regions are a separate polygon set declared in the manifest (`dragRegions: [...]`); Holoscape's chrome views install NSTrackingAreas and call `window.performDrag(with:)` when a mouseDown lands inside one.
- **Fonts** wire through existing `FontDescriptor`. Chrome views call `skinContext.resolvedFont(for: surfaceKey)` in their `layout()` / `refreshFromSkin()` and apply to their `NSTextField` / `NSButton` / custom text renderers.
- **Border / corner / shadow** chrome views call `SkinContext.applyBorderAndCorner(to: layer, from: resolved)` — already implemented — and the new `SkinContext.applyShadow(to: layer, from: resolved)` (thin wrapper around existing shadow code).
- **`.wamp` bundles** are ZIP archives containing `skin.json` + `regions.json` + `assets/` + optional `fonts/`. `SkinEngine.loadComposite` gains a branch: if the resolved skin URL is a `.wamp` file, unzip to a cache directory and resolve from there. Rest of the pipeline unchanged.

```
Skin Bundle (.wamp)           Holoscape Runtime
─────────────────────         ─────────────────────
skin.json        ─────────►  SkinDefinition (v2 + v3 additive fields)
regions.json     ─────────►  WindowShapeRegions (new)
assets/*.png     ─────────►  image cache (+ sprite sheet metadata)
assets/*.ninepatch.json ──►  ninepatch sidecars (existing)
fonts/*.ttf      ─────────►  CTFontManager (existing, consumption wired)
                                     │
                                     ▼
                            SkinContext (+ WindowShape, + SpriteState, + DragRegions)
                                     │
                                     ▼
                            MainWindowController.applySkin
                                     │
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                      ▼
         NSWindow shape      Chrome views (refreshFromSkin)  Hit testing
         (layer.mask)        (applyFill, apply*, fonts)      (draggable regions)
```

## 7) Data Model

**Manifest schema additions (backward compatible; all new fields optional):**

```swift
// Additions to SkinDefinition:
struct SkinDefinition {
    // … existing v1 + v2 fields
    var version: String?                         // existing; bump to "3.0" for Amplify skins
    var windowShape: WindowShapeDescriptor?      // NEW — polygon regions or mask image
    var dragRegions: [DragRegionDescriptor]?     // NEW — skin-declared drag handles
}

// Additions to FillDescriptor.image:
case image(path: String, tile: TileMode, sprite: SpriteDescriptor?)
// sprite is nil → fill the whole image; non-nil → slice cells per state

// NEW types:
struct WindowShapeDescriptor: Codable {
    enum Kind: String, Codable { case polygons, mask }
    var kind: Kind
    var polygons: [Polygon]?              // for kind == .polygons (region.txt analog)
    var maskPath: String?                 // for kind == .mask (PNG alpha)
}

struct Polygon: Codable {
    var points: [Point]                   // [{x: 0, y: 0}, {x: 100, y: 0}, ...]
}

struct DragRegionDescriptor: Codable {
    var polygons: [Polygon]
    var modifier: String?                 // "none" | "command" (optional modifier required to drag)
}

struct SpriteDescriptor: Codable {
    var cellWidth: Int
    var cellHeight: Int
    var rows: Int
    var cols: Int
    var stateMap: [String: SpriteCell]    // "normal", "hover", "pressed", "active", "disabled"
}

struct SpriteCell: Codable {
    var row: Int
    var col: Int
}
```

**SurfaceKey catalog expansion:**

New per-state cases for interactive elements (existing keys stay):
```
tabBar.tab.hover
tabBar.tab.pressed
sidebar.row.hover
sidebar.row.pressed
inputBox.field.focused        (exists? verify)
sessionLauncher.button.normal
sessionLauncher.button.hover
sessionLauncher.button.pressed
readerPanel.titleBar          (new — Reader panel becomes skinnable)
readerPanel.background
readerPanel.closeButton.normal
readerPanel.closeButton.hover
readerPanel.closeButton.pressed
window.shape                  (NEW — the whole-window mask)
window.dragHandle             (NEW — marker for Drag regions to target)
```

**`.wamp` bundle layout:**

```
<name>.wamp                  (ZIP container)
├── skin.json                (manifest; version "3.0")
├── regions.json             (optional, if windowShape uses polygons)
├── assets/
│   ├── *.png                (sprite sheets, fills, masks)
│   └── *.ninepatch.json     (sidecars)
└── fonts/
    └── *.ttf | *.otf        (optional)
```

## 8) Functional Requirements

**F1. Shaped window rendering.**
- Given a skin with `windowShape.kind == polygons`: NSWindow switches to `.borderless`, `isOpaque = false`, `backgroundColor = .clear`. `contentView.layer.mask` = CAShapeLayer with a path built from the polygons. Region vertices are in content-view coordinates.
- Given a skin with `windowShape.kind == mask`: mask layer's contents = the mask PNG (alpha channel interpreted as mask).
- With no `windowShape`: behavior identical to today (titled resizable NSWindow).

**F2. Sprite-sheet button rendering.**
- Given `FillDescriptor.image` with a `SpriteDescriptor`: `SkinContext.applyFill` slices the cell corresponding to the element's current state and sets that cropped image as the layer's contents.
- Chrome views compute their current state (normal / hover / pressed / active / disabled) via existing AppKit hooks (`NSTrackingArea` for hover, button `isPressed` for pressed, etc.) and re-apply the fill on state change.

**F3. Click-through regions.**
- `NSWindow.contentView` overrides `hitTest(_:)` to return nil for points outside the current window-shape region. Events pass through to the window behind Holoscape.
- Hit testing is point-in-polygon (Jordan curve theorem) for polygon shapes, alpha-sample for mask shapes.

**F4. Skin-authored drag regions.**
- On `mouseDown` inside a declared drag region polygon: `window.performDrag(with: event)`.
- Regions install `NSTrackingArea` so the cursor can change (e.g., to an open-hand or move cursor) when hovering a drag region.

**F5. Font consumption in chrome views.**
- `TabBarView`, `SidebarView` / `SidebarTabEntry`, `InputBoxView`, `SessionLauncherView`, `ReaderModeController` each resolve `surface.font` via the skin context and apply to their labels / text fields.
- No font in the manifest → system font (current behavior).

**F6. Border / corner / shadow rendering.**
- Each chrome view calls `skinContext.applyBorderAndCorner(to: layer, from: resolved)` in `refreshFromSkin`.
- New `SkinContext.applyShadow` method applies `ResolvedShadow` to `layer.shadowColor` / `.shadowOpacity` / `.shadowRadius` / `.shadowOffset`.
- Tab buttons specifically honor corner radius from the skin (makes pill-shaped buttons possible).

**F7. `.wamp` bundle loader.**
- `SkinEngine.availableSkins()` enumerates `.wamp` files alongside directories (both in the user dir and the bundle).
- `SkinEngine.loadComposite(named:)` detects `.wamp` URLs, unzips to `~/.holoscape/cache/skins/<hash>/`, and resolves from there. Cache is keyed by SHA-256 of the bundle so an edit invalidates.
- Hot reload: FSEventStream watcher on the bundle file (not the cache) re-unzips + reloads on change.

**F8. Reader panel becomes skinnable.**
- `ReaderModeController` stops hardcoding SF Mono 14pt.
- Reader panel's `NSPanel` subclass accepts a skin context and applies fill / font / border / shape from `readerPanel.*` surface keys.
- A skin that doesn't override `readerPanel.*` keys falls back to today's Reader Mode look (SF Mono 14pt, default chrome) — backward compatible.

**F9. Density-mode interaction.**
- Density `.off` still bypasses the entire skin pipeline (zero-overhead idle chrome — existing contract).
- Density `.minimal` skips sprite sheets and animations (static fills only). Shape masks still apply (no point in using Minimal mode if the window reverts to a rectangle).

## 9) Non-Functional Requirements

- **No hardcoded absolute paths.** Skin directories resolve via `skinsDirectory` (user override: `HOLOSCAPE_CONFIG_DIR`), `Bundle.module.resourceURL` (bundled skins), and unzip cache at `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!` (standard Apple URL). No `~/.holoscape` or `/Users/...` string literals in code.
- **No secrets in code.** No API keys, no tokens. Skin metadata (author, license URL) is user-authored; engine only reads + displays.
- **Safe file operations.** `.wamp` unzip validates paths against the cache root (no `..` traversal, no absolute paths in the ZIP). Same two-layer sandbox as existing image loading (`validateAssetPath` + `assertPathResolvesInside`).
- **Font registration symmetric.** Bundled-skin font URLs drain cleanly on skin unload (existing `SkinFontBundle.registeredURLs` invariant holds).
- **Density `.off` zero-overhead.** Shaped-window code path short-circuits when density is off (window stays titled/rectangular). No FSEventStream watchers, no cache writes.

## 10) UX and UI Requirements

**Skin picker (existing Appearance Settings):**
- Continues to list all skins (bundled + user-dir + `.wamp` files).
- Clicking a `.wamp` file in Finder opens Holoscape and installs/selects the skin (document type registration).
- Selecting a shaped-window skin triggers the borderless-window transition with a brief fade to mask the style-mask change.

**Shape transitions:**
- Switching from a rectangular skin to a shaped skin (or vice versa) is a style-mask change on NSWindow — requires reconstructing the window. Preserve window frame and contents across the swap.
- Window shadow for shaped windows: rely on NSWindow's native shadow (follows the shape once mask is applied). No manual shadow work.

**Drag affordance:**
- When hovering a declared drag region, cursor changes to `NSCursor.openHand` (matches Finder / Preview title-bar drag affordance). On mouseDown, `NSCursor.closedHand`.
- If no drag regions are declared AND the window is borderless, fall back to "whole window is draggable" (standard NSWindow `.isMovableByWindowBackground = true`). Prevents a skin from accidentally shipping an undraggable window.

**Failure modes surfaced to users:**
- Malformed `skin.json`: skin doesn't appear in the picker. NSLog with specific parse error.
- Malformed `regions.json`: skin appears, but shape falls back to rectangle. Log + user notification (small banner at the top of the window for the first 5 seconds: "Skin X: invalid window shape, using rectangle").
- Missing `fonts/*.ttf` referenced in manifest: labels render in system font, log warning.
- Missing sprite sheet image: element falls back to default color, log warning.
- Philosophy: **a broken skin degrades gracefully, never bricks.**

**Accessibility:**
- Shaped / stylized windows still honor macOS Reduce Motion (no fade on skin switch in that mode).
- Shaped windows still honor Reduce Transparency (alpha-masked regions become opaque system-gray).
- VoiceOver: Holoscape's existing accessibility labels remain on chrome views regardless of skin. Skin's visual button can be a bitmap, but its `accessibilityLabel` is code-provided ("Play," "Stop," etc. — wait no, this is a terminal, but the labels for tab-bar / sidebar / input are set in code).
- Minimum "touch target" enforcement: drag regions < 44×44 pt generate a warning at skin-load time (Apple HIG guideline).

## 11) Success Metrics

**Measurable objectives:**

1. **Shape fidelity.** A Winamp-style skin (non-rectangular: rounded corners + a partial-height tab bar that extends beyond the main content) renders correctly. Acceptance: visual diff against a reference screenshot within 5% per-pixel tolerance.
2. **Sprite state coverage.** Tab buttons in 4 states (normal, hover, pressed, active) each pull the correct sprite cell. Acceptance: 4-state hover/click regression test passes on Mac Mini.
3. **Drag UX.** Grabbing a declared drag region moves the window. Acceptance: UI test simulating mouseDown+drag on the drag region moves `window.frame.origin` by the drag delta (within 1 pt).
4. **Typography.** Tab titles render in the skin's TTF. Acceptance: screenshot comparison at a magnified region shows the skin font's distinctive glyphs, not SF Mono.
5. **Backward compat.** Existing `HoloscapeSynthwave` directory-layout skin continues to work with no manifest changes. Acceptance: bisect test that switches between Synthwave and the new Amplify skin multiple times without hot-reload glitches.
6. **`.wamp` round-trip.** `HoloscapeSynthwave` ported to `.wamp`, dropped in `~/.holoscape/skins/`, loads identically to the directory-layout version. Acceptance: pixel-identical chrome across both sources (on the same monitor / same backing scale).
7. **Hot reload speed.** Edit `skin.json` inside a `.wamp`, save: chrome updates within 200 ms. (Requires re-unzipping; watch the ZIP mtime, invalidate cache, reload.) Acceptance: existing `HotReloadTests`-style integration test extended for `.wamp`.
8. **Density-off zero-overhead.** With density `.off`, no FSEventStream watchers active, no cache reads, no skin-engine allocations. Acceptance: existing `testZeroOverheadWhenOff` property test extended to cover Amplify entry points.
9. **Shipped Winamp-evocative skin.** One skin bundled with the app that subjectively "looks like Winamp." Erik's sign-off on dogfood = the gate.

## 12) MVP Scope

**Day-1 deliverable: Erik sees a non-rectangular Holoscape window with a sprite-art tab button and a skin-font tab title.**

In scope for MVP:
- Shaped windows via polygon regions (mask-image shapes = post-MVP)
- Sprite-sheet image fills with `normal` / `pressed` / `hover` states (more states post-MVP)
- Click-through outside polygon regions
- Drag regions (whole-window-draggable fallback when none declared)
- Font consumption on `TabBarView` + `SidebarView` + `InputBoxView` (Reader Mode font = post-MVP)
- Border + corner + shadow wiring on all chrome views
- `.wamp` bundle loader + cache
- **One new reference skin** that exercises the above: "Holoscape Classic" — deliberately Winamp-evocative aesthetic. Rectangular-with-cut-corners shape + bitmap-style buttons + pixel font. Erik sources the art (or I can generate a lo-fi procedural version as placeholder).

**Ported to Amplify format (MVP):** `HoloscapeSynthwave` repackaged as a `.wamp` (no new art; proves backward-compat + bundle path).

Post-MVP ladder (see §13):
- Mask-image (PNG alpha) shapes
- More sprite states (active, disabled, focused)
- Reader Mode panel fully skinnable
- Drop-in `.wamp` via Finder double-click
- `.wsz` → `.wamp` converter
- Bitmap font support (Winamp-faithful NUMBERS.BMP / TEXT.BMP)

## 13) Post-MVP

**Phase 2:**
- **Mask-image shapes.** PNG alpha interpreted as window mask. Enables blobs, curves, complex silhouettes a polygon list can't express.
- **Reader Mode panel skinnable.** Reader panel accepts a skin context; `readerPanel.*` surface keys drive its chrome.
- **All sprite states.** Add `focused`, `disabled`, `selected` sprite rows beyond MVP's normal/hover/pressed.
- **Finder double-click install.** Register `.wamp` as a document type; dragging one onto Holoscape or double-clicking installs into `~/.holoscape/skins/`.
- **Per-skin settings.** Some skins want to expose "dark variant" / "bright variant" toggles; add a `settings` block in the manifest that surfaces radio-button UI in Appearance Settings.

**Phase 3:**
- **`.wsz` → `.wamp` converter.** Automated tool that ingests an original Winamp 2 `.wsz` and produces a `.wamp` that approximates it in Holoscape. Maps CBUTTONS.BMP to our tab-button sprite, NUMBERS.BMP/TEXT.BMP to a bitmap-font renderer, region.txt to our windowShape polygons, viscolor.txt to the shader pipeline if relevant.
- **Bitmap font renderer.** For Winamp-faithful typography, a CALayer-based bitmap-font renderer that tiles glyphs from a sprite sheet at fixed offsets.
- **Visual skin editor.** A separate app (or a Holoscape panel) that lets a designer edit a `.wamp` live: drop in a sprite sheet, drag region vertices, preview in real time. Uses the existing hot-reload plumbing.
- **Skin store / registry.** A curated gallery of community skins with screenshots, download links, and license metadata. Probably a plain GitHub Pages site that links to `.wamp` files.

## 14) Constraints and Governance

**Engineering:**
- Follow project governance and review protocol: code-reviewer subagent PASS before every PR, `/pr` skill for all pull requests, auto-merge via `gha pr merge --auto --merge`, never direct-push to main.
- Use validation commands before completion: `swift test`, `swift build`, `./bundle.sh`.
- Update parent task tracker: `claude-specs/chrome-skinning/tasks.md` is the parent spec for this work; Amplify gets its own spec in `claude-specs/amplify/` once Kiro generates it.
- Mac Mini dogfood after every PR's merge. Visual regressions require screenshot comparison on Mac Mini (laptop GUI testing is forbidden per project convention).
- Commit hygiene: task-ID linking, Co-Authored-By on every commit, `gha` identity wrapper.

**Product:**
- Every Amplify PR must include backward-compat verification: existing `HoloscapeSynthwave` skin continues to work unchanged.
- Every new manifest field is optional and has a documented default that reproduces pre-Amplify behavior.
- Every new chrome-view consumption path has a "no skin wired" fallback that matches the pre-skinning constant.

**Risk gating:**
- Shaped-window PR must ship with a feature flag (`HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS=1` env var) so we can isolate shape-related rendering bugs without reverting the whole PR.

## 15) Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| NSWindow style-mask transition (titled → borderless) glitches: frame jumps, contents flicker, focus loss | High | Medium | Preserve frame explicitly across the swap; use `NSAnimationContext` fade to mask; extensive Mac-Mini dogfood |
| Shaped windows + multi-monitor edge cases (dragging across displays with different scales) | Medium | Medium | Existing `backingScaleFactor` plumbing applies; add integration test that simulates cross-display drag |
| Shaped windows break the "click-through" expectation for menus / popovers that overlap the masked regions | Medium | High | Menus / popovers are independent NSWindows; their hit-testing is unaffected by our contentView mask. Verify in dogfood. |
| `.wamp` cache fills up on disk (every skin edit triggers a new unzip) | Low | Low | LRU cache with 50 MB cap; purge policy runs on startup |
| Font registration leaks across bundles (same PostScript name from two different .wamp files) | Low | Medium | `SkinFontBundle.registeredURLs` invariant already handles this; regression tested |
| macOS Reduce Motion / Reduce Transparency users see broken shapes | Low | Medium | Accessibility branches covered in §10; integration test with the env vars |
| Skin author writes polygons outside the content view bounds: window clips to invisible regions, appears "disappeared" | Medium | High | Validation at load time: reject manifests with polygons that don't overlap the nominal bounds; offer a "reset to rectangle" fallback; log clearly |
| Sprite sheet cell-coordinate math off-by-one in `SkinContext.applyFill` produces visible tears at sprite edges | Medium | Low | Unit test every sprite slice at pixel coordinates; fuzz with property tests over arbitrary cell grids |
| `.wamp` bundle zip-bomb attack (1 GB of pink pixels) | Low | High | File-size cap at 50 MB per asset inside the bundle; abort unzip on cap breach; logged + user notification |
| Hot reload in `.wamp` path races with Finder operations (editing the zip mid-reload) | Medium | Low | Debounce already handles this. Add a test for "bundle modified mid-unzip"; fallback is keep-previous-SkinContext. |
| Designer expectations for Amplify-format don't match what the runtime supports | High | Medium | Ship a single well-documented format spec (`docs/amplify-format.md`) with illustrated examples. Update as the engine evolves. |

## 16) Dependencies

**External:**
- **AppKit** — `NSWindow`, `NSPanel`, `CAShapeLayer`, `CATrackingArea`, `NSEvent` drag handling. Already in use.
- **Core Text** — TTF registration via `CTFontManagerRegisterFontsForURL`. Already in use.
- **Foundation / ZIP** — `Archive.framework` or third-party `ZIPFoundation` package for unzipping `.wamp`. Current Package.swift has no ZIP dependency; adding `ZIPFoundation` is the proposed path (MIT-licensed, pure Swift, well-maintained).

**Internal (Holoscape):**
- Chrome-skinning parent spec (merged, no blockers)
- `SkinEngine` / `SkinContext` / `SurfaceDescriptor` model (extending, not replacing)
- `ReactiveUniformSnapshot` (Reader Mode / state-variant matcher; minimal changes expected)
- Shader pipeline (unrelated; Amplify doesn't touch it)

**Blocks no other project.** Amplify is a visual / chrome feature; other Holoscape features (channels, sessions, API server) proceed independently.

## 17) Open Items

- **Art sourcing.** Erik sources / commissions the "Holoscape Classic" reference skin art. Until then, MVP can ship with a procedural placeholder (generated gradients + simple sprites).
- **Bitmap font path for post-MVP.** Decide whether to implement a true bitmap-font renderer (for `.wsz` converter support) or require all Amplify fonts to be TTF. Leaning TTF-only.
- **`.wamp` signature / integrity.** Should `.wamp` bundles be signed (for gatekeeper-style trust in community skins)? Unclear. Defer to a post-MVP security pass.
- **Reader Mode font override.** Task 12 hardcoded SF Mono 14pt. Should Amplify skin `readerPanel.font` override that, or does the Reader Mode user intent ("quiet surface for reading") mean font should always be SF Mono regardless of skin? Leaning "skinnable with an opt-out for accessibility users."
- **Window-shape animation during hot reload.** If a skin reloads with a new window shape, should the mask transition animate? Technically easy; aesthetically questionable. Open for dogfood feedback.
- **Skin author tooling.** Do we ship a companion "skin linter" CLI? Useful for catching malformed manifests before distribution. Post-MVP at earliest.
- **Test infrastructure for shaped windows.** Hit-testing tests need an NSWindow + event simulation. `XCUITest` on Mac Mini is one option; unit-level `hitTest` tests with synthetic mouse events is another. Decide during implementation.
- **Density-mode semantics for shapes.** `.off` → rectangular fallback. `.minimal` → keep shape but static fills. `.full` → full shape + animation. Confirmed, but the `.minimal` + shape combination may look weird; dogfood on Mac Mini to validate.
- **Window shadow on shaped windows.** NSWindow's auto-shadow follows the mask in AppKit ≥ 10.6; confirm on current macOS. If not, we construct a shadow layer manually.
- **Cross-platform signaling.** If Holoscape ever gets a Linux port, `.wamp` should ideally Just Work. Keep format platform-agnostic (no macOS-specific paths or plists in the manifest). Design for it even though Amplify ships macOS-only.

---

**Next step:** Run this PRD through `/spec` (Kiro-format spec generation) to produce `claude-specs/amplify/{requirements,design,tasks}.md`. That gives us a mechanical task list to burn down.
