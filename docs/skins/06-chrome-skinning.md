# Chrome Skinning — Non-Shader Surface Design for Holoscape

> **Status:** Design, draft 1 (#5929). Companion to [`05-reactive-uniforms.md`](./05-reactive-uniforms.md). Together they define the full Holoscape skin system.
> **Feeds:** scope doc #5887 and future implementation cards (not yet filed).

---

## 1. Purpose

Holoscape's skin system has two layers:

- **Shader layer** — pixels *inside* the terminal viewport, driven by a GLSL fragment shader. Covered in detail in [`05-reactive-uniforms.md`](./05-reactive-uniforms.md) and [`04-ghostty-investigation.md`](./04-ghostty-investigation.md). Borrowed wholesale from Ghostty, extended with Holoscape's agent-state uniform surface.
- **Chrome layer** — everything *outside* the terminal viewport: the tab bar, sidebar, input box, window title bar area, settings panel, split divider, dialogs. This layer has no equivalent in Ghostty, which is why Erik's "feels like Winamp 5" vision lives here. **This doc is about the chrome layer.**

The goal: a skin author describes chrome appearance in a declarative manifest, Holoscape renders it at runtime, and chrome reacts to the same semantic events the shader layer already reacts to (agent state, command lifecycle, notifications, channel activity).

## 2. Prior art: what Holoscape already has

A skin infrastructure already exists in the codebase but is **shallow and mostly unused**. Before writing this design I audited it. Summary:

**Models / services** (`Sources/Holoscape/`)

- [`Models/SkinDefinition.swift`](../../Sources/Holoscape/Models/SkinDefinition.swift) — a flat `Codable` struct with 11 optional fields: `windowBackground`, `titleBarBackground`, `sidebarBackground`, `tabActiveColor`, `tabInactiveColor`, `textForeground`, `ansiColors[16]`, and three background-image paths (`windowBackgroundImage`, `sidebarBackgroundImage`, `tabBarBackgroundImage`).
- [`Services/SkinEngine.swift`](../../Sources/Holoscape/Services/SkinEngine.swift) — loads `skin.json` from `~/.holoscape/skins/<name>/` (or `$HOLOSCAPE_CONFIG_DIR/skins/<name>/`), applies color fields to `AppearanceConfig`, ignores image fields.
- [`Services/ColorTheme.swift`](../../Sources/Holoscape/Services/ColorTheme.swift) — six built-in themes (Dark, Monokai, Solarized Dark/Light, Dracula, Nord) mapping to background / foreground / 16 ANSI colors.
- [`Models/HoloscapeConfig.swift`](../../Sources/Holoscape/Models/HoloscapeConfig.swift) `AppearanceConfig` — the runtime skin state: `backgroundColor`, `transparency`, `fontFamily`, `fontSize`, `ansiColors`, `themeName`, `themeOverrides`, `skinName`.

**What this gives us today**

- JSON-based manifest loading from a known directory with per-skin subfolders.
- Color + theme switching for terminal foreground / background / ANSI palette.
- An `AppearanceConfig` object that Chrome *could* read from, but doesn't.

**What's broken / missing** (the design below is how we fix these)

1. **Chrome views hardcode their colors.** `TabBarView.swift` defines `static let activeTabBg = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor` and uses it at compile time. The skin system literally cannot reach these values — changing `skin.json` does nothing to the tab bar's actual appearance. 18 hardcoded color call sites across 6 view files (`SessionLauncherView`, `AppearanceSettingsView`, `InputBoxView`, `TabBarView`, `TerminalContainerView`, `SidebarView`).
2. **No image asset path resolution.** `SkinDefinition` declares `windowBackgroundImage` and two other image fields, but `SkinEngine.apply(skin:to:)` never touches them.
3. **No ninepatch / stretchable images.** A background image is a flat PNG. You can't describe "this image is a button frame whose center stretches."
4. **No surface descriptors.** There's no way to say "the tab bar has this shape, this corner radius, this border, this animation curve." Everything surface-level is hardcoded.
5. **No state reactivity in chrome.** `TabBarView` already has per-tab notification colors (`permissionBg`, `idleBg`) but they're manually driven by a hardcoded dictionary of notification types. A skin author cannot add a new reactive state or change how one animates.
6. **No hot reload.** Edit `skin.json` → nothing happens until restart.
7. **No font loading from skin.** `AppearanceConfig.fontFamily` uses whatever's installed system-wide. Skins can't ship their own bitmap or vector fonts.

So this design is **not** inventing a skin system from scratch — it's evolving the existing one into something that can actually restyle chrome.

## 3. Scope

**In scope**

- A schema evolution of `SkinDefinition` (call it `SkinManifest v2`) that describes chrome surfaces structurally.
- A per-surface descriptor model: shape, fill (color / image / gradient), border, padding, animation, state variants.
- A migration plan for wiring every chrome view to read its appearance from the manifest at runtime.
- An asset pipeline (images, ninepatch sidecars, fonts) with deterministic path resolution.
- A state/event model so chrome reactivity uses the same agent-state atomic snapshots that `05-reactive-uniforms.md` defines for the shader layer.
- How chrome composes with the shader layer (z-order, compositing boundary, clipping).
- Hot reload via FSEventStream on the skin directory.
- Backward compatibility with existing `SkinDefinition v1` files — v1 keeps working, v2 adds new fields.

**Out of scope**

- The shader layer — #5928, [`05-reactive-uniforms.md`](./05-reactive-uniforms.md).
- Agent-state uniform contents — #5928.
- The per-tab "last interaction" stale-tab badge — #5936. *Chrome reacts to the same events, but that specific feature is a wall-clock UI behavior, not a skin behavior.* The stale-tab feature uses the chrome skinning system once it exists, but doesn't drive its design.
- A skin authoring GUI. Authors edit JSON by hand in v2. A GUI editor is a plausible future card once the schema is stable.
- Animated mouse-reactive chrome (hover effects tied to cursor tracking). Deferred — current scope is semantic-state reactivity, not pointer reactivity.
- Winamp 5 Maki-style scripting. A scripting layer is the ceiling; v2 design is limited to declarative state machines.

## 4. Design constraints

Four hard rules, in priority order:

1. **Backward compatibility with `SkinDefinition v1`.** The 11 existing fields keep their names, types, and semantics. A v1 skin.json still loads and still renders correctly. This is non-negotiable — we may have users with v1 skins already on disk (zero today, but we're not going to break them on schema change).
2. **Declarative manifest, not code.** A skin is `skin.json` plus a folder of assets. No compiled code, no scripting VM. Rationale: skins must be safe to download from the internet without a code-review gate, and the existing system is already JSON.
3. **No chrome view draws its own colors.** Every visual property (color, image, corner radius, border, animation) is resolved through a single `SkinContext` object at render time. Hardcoded values in view files are prohibited after the wiring migration. This is the rule that makes every subsequent skin feature possible — if it's not in the context, the skin can't affect it.
4. **Chrome state reactivity reuses the shader-layer atomic snapshots from §6.2 of `05-reactive-uniforms.md`.** We do not build a second event bus. Chrome's update tick is slower (CADisplayLink-equivalent or a 30-60Hz timer, not per-shader-frame), but the source of truth is the same `ReactiveUniformSnapshot` instance.

## 5. Decisions already made

Two questions I framed in `04-ghostty-investigation.md` §A.7 as "open" are actually **closed by the existence of the current system** and don't need to be re-decided:

- **Declarative manifest vs. imperative SwiftUI with skin state.** *Closed: declarative.* `SkinDefinition` is already a JSON `Codable`. We extend the JSON; we do not switch to SwiftUI view modifiers gated on skin state. Rationale beyond backward compat: JSON skins can be distributed as a single archive, reviewed at a glance, and edited without a compiler. Imperative SwiftUI requires code trust we don't want to grant to skin authors.
- **Where does the manifest live.** *Closed: `~/.holoscape/skins/<name>/skin.json`*, with `$HOLOSCAPE_CONFIG_DIR` override — matches `SkinEngine.swift` today.

One question remains genuinely open and is flagged for decision in §13.

## 6. Surface catalog

The complete set of chrome surfaces, derived from walking `Sources/Holoscape/Views/`. Every item below becomes a top-level key under `surfaces:` in the v2 manifest.

| Surface | Driven by view file | Current state |
|---|---|---|
| `window.titleBar` | system-provided (`NSWindow.titlebarAppearsTransparent` + traffic lights) | Holoscape already configures this; skin can tint and set a material |
| `window.background` | `MainWindowController` / `AppearanceConfig.backgroundColor` | Partially skinnable via `AppearanceConfig`, not via `SkinDefinition` images |
| `tabBar.container` | `TabBarView` | Hardcoded `barBg` color |
| `tabBar.tab.active` | `TabBarView` | Hardcoded `activeTabBg` |
| `tabBar.tab.idle` | `TabBarView` | Hardcoded `idleBg` |
| `tabBar.tab.permission` | `TabBarView` | Hardcoded `permissionBg` |
| `tabBar.tab.normal` | `TabBarView` | Hardcoded `NSColor.lightGray` text on nil bg |
| `tabBar.tab.unreadMarker` | `TabBarView.buildTabTitle` | Hardcoded unicode bullet `●` |
| `sidebar.container` | `SidebarView` | 7 hardcoded colors |
| `sidebar.row.normal` | `SidebarView` | Hardcoded |
| `sidebar.row.selected` | `SidebarView` | Hardcoded |
| `sidebar.row.hover` | `SidebarView` | Hardcoded |
| `sidebar.sectionHeader` | `SidebarView` | Hardcoded |
| `inputBox.container` | `InputBoxView` | Hardcoded |
| `inputBox.field` | `InputBoxView` | Hardcoded |
| `inputBox.placeholder` | `InputBoxView` | Hardcoded |
| `sessionLauncher.container` | `SessionLauncherView` | Hardcoded |
| `sessionLauncher.row` | `SessionLauncherView` | Hardcoded |
| `splitPane.divider` | `SplitPaneView` / `SplitPaneManager` | Not yet audited (follow-up spike) |
| `terminalContainer.padding` | `TerminalContainerView` | Hardcoded |
| `settings.panel` | `AppearanceSettingsView` | Hardcoded |
| `dialog.container` | `BugReportDialog` | Hardcoded |

**23 surfaces.** Not all need to ship in v2 — the migration plan in §10 prioritizes the high-visibility ones first (tab bar, sidebar, input box, window).

Surface names are hierarchical (`tabBar.tab.active`) so the manifest can define defaults at a parent level and override at leaves.

## 7. Surface descriptor model

Each surface is described by a JSON object with this shape. Every field is optional; a surface that omits everything falls back to Holoscape's built-in defaults (the same values currently hardcoded in the view files).

```json
{
  "fill": { ... },
  "border": { ... },
  "corner": { ... },
  "padding": { "top": 0, "right": 0, "bottom": 0, "left": 0 },
  "shadow": { ... },
  "font": { ... },
  "text": { ... },
  "animation": { ... },
  "states": { ... }
}
```

### 7.1 `fill`

Describes the background of the surface. One of three variants, selected by a `kind` tag:

```json
{ "kind": "color", "value": "#1a1a2e" }
```

```json
{ "kind": "image", "path": "assets/tab-bg.png", "tile": "stretch" }
```

```json
{
  "kind": "gradient",
  "direction": "vertical",
  "stops": [
    { "offset": 0.0, "color": "#1a1a2e" },
    { "offset": 1.0, "color": "#0e0e1a" }
  ]
}
```

**Tile modes for `image`:** `stretch` (default — resize to surface bounds), `tile` (repeat), `ninepatch` (see §8).

### 7.2 `border`, `corner`, `shadow`

```json
{
  "border": { "color": "#000000", "width": 1.0 },
  "corner": { "radius": 8.0 },
  "shadow": { "color": "#000000", "opacity": 0.4, "blur": 12.0, "offsetX": 0.0, "offsetY": 4.0 }
}
```

`corner.radius` can also be a 4-tuple `[tl, tr, br, bl]` for asymmetric rounded corners (curved-tab-bar territory).

### 7.3 `font` and `text`

```json
{
  "font": { "family": "Px437 IBM VGA 8x16", "size": 11.0, "weight": "regular" },
  "text": { "color": "#ffffff", "shadow": { "color": "#000000", "blur": 2.0 } }
}
```

`font.family` can reference a system font OR a font file shipped with the skin (`assets/fonts/...`). See §9 for font loading.

### 7.4 `animation`

Describes how property changes animate. Every property that can animate has an optional default curve, overridden here per-surface:

```json
{
  "animation": {
    "default": { "duration": 0.2, "curve": "easeInOut" },
    "fill": { "duration": 0.35, "curve": "easeOut" },
    "corner.radius": { "duration": 0.15, "curve": "linear" }
  }
}
```

Curve names: `linear`, `easeIn`, `easeOut`, `easeInOut`, `spring`. No custom bezier control points in v2 — add later if needed.

### 7.5 `states`

The reactive dimension. Every surface can define state-variant overrides. States are keyed by a small enum and a match expression. The match expression is a tiny subset of JSON that checks values from the shared `ReactiveUniformSnapshot` (same source as shader uniforms):

```json
{
  "states": {
    "agentThinking": {
      "match": { "agentState": 1 },
      "fill": { "kind": "color", "value": "#2a2a50" }
    },
    "agentError": {
      "match": { "agentState": 3 },
      "fill": { "kind": "color", "value": "#5a1a1a" },
      "animation": { "fill": { "duration": 0.4, "curve": "easeOut" } }
    }
  }
}
```

States are evaluated in order; the last matching state wins. If no state matches, the surface's base descriptor is used. The manifest can describe arbitrary states on arbitrary surfaces — a skin can tint the sidebar red when *any* agent errors, or only when the *current channel's* agent errors, by using different match keys.

**Allowed `match` keys** (all from `ReactiveUniformSnapshot`):

- `agentState` (int): 0/1/2/3
- `commandState` (int): 0/1/2
- `lastCommandExitCode` (int)
- `channelIsActive` (int): 0/1
- `channelUnread` (int): compared with `==`, `>=`, etc. via `{ "channelUnread": { "$gte": 1 } }`
- `notificationKind` (int): 0/1/2/3
- `timeSince` (object): `{ "timeSince": { "iTimeAgentStateChange": { "$lt": 0.6 } } }` — computed as `(now - iTimeX)`, useful for chrome-side fades

The match DSL is deliberately tiny. If a skin needs more than this, it's a sign the scripting ceiling (out of scope for v2) is pulling on us; we should push back on the request, not extend the match language.

## 8. Images and ninepatch

### 8.1 Asset path resolution

All `path` fields in the manifest are resolved relative to the skin's own directory (`~/.holoscape/skins/<name>/`). Absolute paths, `..` traversal, and HTTP URLs are rejected. Rationale: a skin archive must be self-contained, and we don't want to load assets from unknown locations on disk or the network.

### 8.2 Ninepatch sidecar

For image fills that need to stretch only the middle of an image (window frames, button backgrounds), the v2 manifest supports a ninepatch sidecar. If an image is `assets/tab-bg.png`, the ninepatch spec lives at `assets/tab-bg.ninepatch.json`:

```json
{
  "stretchX": [16, 48],
  "stretchY": [8, 24]
}
```

`stretchX` and `stretchY` describe the range of pixels in the source image that may be stretched; pixels outside that range are drawn at 1:1 scale. This is functionally the Android 9-patch model without the inline `.9.png` pixel-border convention.

A fill that points at an image with a ninepatch sidecar automatically uses `tile: "ninepatch"` — the skin doesn't need to declare it twice.

### 8.3 Image loading

Images are loaded via `NSImage(contentsOfFile:)` on the main thread at skin-apply time. They're cached per-skin in the `SkinContext` (see §10) and released when the skin is unloaded. No background loading, no on-demand loading — skins are small enough that loading everything up front is fine and predictable.

## 9. Fonts

A skin can ship fonts alongside images. The `font.family` field, if it references a family that isn't installed system-wide, is resolved against `assets/fonts/` in the skin directory. `.otf` and `.ttf` are supported.

Font registration uses `CTFontManagerRegisterFontsForURL` scoped to the process (not persistent — we don't pollute the user's font book). Registration happens at skin-load time; deregistration happens at skin-unload time.

This gives us "Winamp 5 shipping its own pixel font" parity for free.

## 10. Wiring chrome views to the skin: the migration pattern

The single biggest implementation task in this design is moving 18 hardcoded color call sites across 6 view files onto a runtime-resolved `SkinContext`. Here's the pattern:

### 10.1 `SkinContext`

A new main-actor object built from an applied skin. It holds resolved values for every surface in §6:

```swift
@MainActor
final class SkinContext {
    struct ResolvedSurface {
        let fill: ResolvedFill      // .color(NSColor) | .image(NSImage, TileMode) | .gradient([...])
        let border: ResolvedBorder?
        let corner: ResolvedCorner
        let padding: NSEdgeInsets
        let shadow: NSShadow?
        let font: NSFont?
        let text: ResolvedText
        let animation: ResolvedAnimation
        let states: [StateName: StateOverride]
    }

    let surfaces: [SurfaceKey: ResolvedSurface]
    let reactive: ReactiveUniformSnapshot   // shared with shader layer

    func resolve(_ key: SurfaceKey) -> ResolvedSurface { surfaces[key] ?? .default }
    func currentState(for key: SurfaceKey) -> ResolvedSurface { /* apply state overrides */ }
}
```

`SurfaceKey` is an enum whose cases correspond to the keys in §6 — compile-time type-safe. A chrome view asks for its surface by enum case, not by string, so rename drift is caught by the compiler.

### 10.2 Migration of a hardcoded view — worked example

Before (`TabBarView.swift` today):

```swift
private static let barBg = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0).cgColor
...
wantsLayer = true
layer?.backgroundColor = Self.barBg
```

After:

```swift
// SkinContext is injected at view construction time (from MainWindowController).
private let skin: SkinContext

override func layout() {
    super.layout()
    let surface = skin.currentState(for: .tabBarContainer)
    surface.applyFill(to: layer)          // handles color/image/gradient
    surface.applyCornerAndBorder(to: layer)
}
```

The hardcoded `barBg` literal is deleted. `SkinContext` extensions (`applyFill(to:)`, `applyCornerAndBorder(to:)`) centralize all the CALayer-poking into one place so no view has to re-implement image/gradient handling.

### 10.3 Migration order

Do not migrate all 23 surfaces at once. Prioritize:

1. **`window.background`** and **`tabBar.*`** — highest visibility, smallest view count.
2. **`sidebar.*`** — second-highest visibility, 7 hardcoded colors to move.
3. **`inputBox.*`** — three surfaces, clear boundaries.
4. Everything else on an as-needed basis.

Each surface migration is one small PR that deletes hardcoded colors from one view file and wires it to `SkinContext`. **Ship a passing XCUITest for each migrated view** so we catch skin regressions as the surface count grows.

## 11. Composition with the shader layer

The shader layer from `05-reactive-uniforms.md` only renders *inside* the terminal viewport (the `HoloscapeTerminalView`'s bounds). Chrome lives *outside* that viewport. These two layers compose cleanly because they don't overlap.

```
┌───────────────────────────────────────────────┐
│ window.titleBar   [chrome]                    │
├─────────┬─────────────────────────────────────┤
│ sidebar │ tabBar  [chrome]                    │
│ [chrome]├─────────────────────────────────────┤
│         │                                     │
│         │    ┌──── terminal viewport ─────┐   │
│         │    │                            │   │
│         │    │     [shader layer here]    │   │
│         │    │  (iChannel0 = terminal fb) │   │
│         │    │                            │   │
│         │    └────────────────────────────┘   │
│         │                                     │
│         ├─────────────────────────────────────┤
│         │ inputBox  [chrome]                  │
└─────────┴─────────────────────────────────────┘
```

**Z-order.** Chrome surfaces draw in their own AppKit view hierarchy; the shader layer is a Metal-backed sublayer of the terminal view. They never overlap at the pixel level, so there's no compositing negotiation needed. The shader never peeks outside its viewport, and chrome never draws into it.

**The one seam**: the visual boundary between chrome and shader. For a Winamp-5-style skin where the tab bar curves *into* the terminal area, v2 solves this by making the chrome surface's `corner` descriptor allow negative radii or a `mask` image that defines the cut-out. The shader layer is always rectangular and clipped by the terminal viewport; chrome can draw on top of the shader near the boundary to visually blend the two. This is the same pattern as Safari's liquid glass — the rectangular content is underneath, the chrome on top defines the shape.

A worked composition example lives in §12.

## 12. State and event model

Chrome reactivity reads from the same `ReactiveUniformSnapshot` that drives the shader layer (`05-reactive-uniforms.md` §6.2). Rationale: one source of truth for agent state; no drift between "what the shader sees" and "what the chrome sees"; free reuse of the lock-free atomics already specified for #5930.

**Update tick.** Shader layer runs at render frame rate (typically 60Hz). Chrome doesn't need that — surface descriptor changes are tied to state transitions, not per-frame animation curves. The chrome system uses a `CADisplayLink` (or equivalent) at 60Hz during active transitions, falling back to event-driven redraws when nothing is animating. **In practice:** when a state transition fires on any surface, start a display link for the duration of the longest pending animation across all surfaces, then stop it. Idle chrome draws zero frames per second.

**State evaluation.** Every tick (whether driven by a state transition or by an active animation), the chrome system walks each visible surface, reads its state declarations, evaluates the `match` expressions against the current snapshot, and picks the winning state (last match wins, same as CSS cascade order). If the winning state differs from the previous tick's, the surface kicks off its `animation` for the affected properties.

**Important distinction, again.** The millisecond-scale animation timestamps from `05-reactive-uniforms.md` §6 (`iTimeAgentStateChange`, etc.) are the same values the chrome layer reads. They are **not** the per-tab wall-clock "last user interaction" timestamp from card #5936 — that feature is independent of the skin system. The stale-tab badge reads chrome state, but its *threshold* comes from a separate channel model.

## 13. Worked example — a complete skin manifest

```json
{
  "name": "Holoscape Classic Winamp",
  "version": "2.0",
  "author": "Example",
  "description": "Rounded tabs, pixel font, agent-reactive chrome.",

  "surfaces": {
    "window.background": {
      "fill": { "kind": "color", "value": "#0a0a18" }
    },

    "tabBar.container": {
      "fill": {
        "kind": "gradient",
        "direction": "vertical",
        "stops": [
          { "offset": 0.0, "color": "#1a1a2e" },
          { "offset": 1.0, "color": "#0e0e1a" }
        ]
      },
      "padding": { "top": 4, "right": 8, "bottom": 4, "left": 8 }
    },

    "tabBar.tab.active": {
      "fill": { "kind": "image", "path": "assets/tab-active.png" },
      "corner": { "radius": [12, 12, 0, 0] },
      "font": { "family": "Px437 IBM VGA 8x16", "size": 11.0 },
      "text": { "color": "#ffffff" },
      "animation": { "default": { "duration": 0.2, "curve": "easeOut" } },
      "states": {
        "agentError": {
          "match": { "agentState": 3 },
          "fill": { "kind": "color", "value": "#5a1a1a" },
          "animation": { "fill": { "duration": 0.35, "curve": "easeOut" } }
        },
        "agentThinking": {
          "match": { "agentState": 1 },
          "fill": { "kind": "color", "value": "#1a2a5a" }
        }
      }
    },

    "tabBar.tab.normal": {
      "fill": { "kind": "color", "value": "#1a1a2e" },
      "corner": { "radius": [8, 8, 0, 0] },
      "text": { "color": "#8080a0" },
      "states": {
        "unreadHasArrived": {
          "match": { "channelUnread": { "$gte": 1 } },
          "fill": { "kind": "color", "value": "#2a2a50" },
          "text": { "color": "#ffffff" }
        }
      }
    },

    "sidebar.container": {
      "fill": { "kind": "image", "path": "assets/sidebar-bg.png", "tile": "ninepatch" }
    },

    "inputBox.container": {
      "fill": { "kind": "color", "value": "#141428" },
      "corner": { "radius": 6 },
      "border": { "color": "#2a2a50", "width": 1 },
      "padding": { "top": 6, "right": 10, "bottom": 6, "left": 10 }
    }
  }
}
```

Assets shipped alongside:

```
~/.holoscape/skins/Holoscape Classic Winamp/
├── skin.json
└── assets/
    ├── tab-active.png
    ├── sidebar-bg.png
    ├── sidebar-bg.ninepatch.json      { "stretchX": [8, 120], "stretchY": [16, 240] }
    └── fonts/
        └── Px437_IBM_VGA_8x16.ttf
```

## 14. Hot reload

`SkinEngine` adds an FSEventStream watcher on `~/.holoscape/skins/<currentSkinName>/`. On any file change under that path (with debounce):

1. Reload `skin.json`.
2. Re-resolve the `SkinContext`.
3. Re-apply font registrations (deregister old, register new).
4. Post a `SkinDidChange` notification.
5. All chrome views observing the notification call their own `layout()` to pick up new values. `SkinContext.applyFill(to:)` handles the repaint; there's no "which views need redrawing" bookkeeping because `layout()` is cheap.

This is the core dogfooding story — a skin author edits `skin.json` in their editor and sees the change live in Holoscape with no restart.

## 15. Implementation checklist (for follow-up cards, not #5930)

The skin system is independent of the shader pipeline, so #5930 (port Ghostty's shader pipeline) does **not** need to wait for chrome skinning. Chrome skinning can land in parallel. Future cards to file from this doc:

- [ ] **Extend `SkinDefinition` with v2 optional fields.** Add a `surfaces` dictionary, keep all v1 fields for backward compat, add a `version` tag. One PR, no behavior change yet.
- [ ] **Build `SkinContext` and the resolver.** Loads v1 + v2 skins, produces `ResolvedSurface` per surface key, owns the `ReactiveUniformSnapshot` reference. Shipped with unit tests covering v1-compat, v2 inheritance, state match evaluation.
- [ ] **Wire `window.background` and `tabBar.*` surfaces first.** Delete the 4 hardcoded colors in `TabBarView`. Add XCUITest that verifies a loaded skin changes the tab bar's rendered color.
- [ ] **Wire `sidebar.*`.** 7 hardcoded colors in `SidebarView`.
- [ ] **Wire `inputBox.*`.** 3 surfaces.
- [ ] **Wire `splitPane.divider`, `settings.panel`, `dialog.container`, `sessionLauncher.*`, `terminalContainer.padding`.** The long tail.
- [ ] **Image fill resolver.** Handle `kind: "image"` with stretch / tile / ninepatch modes. Ninepatch sidecar loader.
- [ ] **Gradient fill resolver.** CAGradientLayer wrapping.
- [ ] **Font registration via `CTFontManagerRegisterFontsForURL`.** Process-scoped, deregister on unload.
- [ ] **Animation engine.** Translates `animation` descriptors into CABasicAnimation / CASpringAnimation. Driven by the state-evaluation tick.
- [ ] **State match DSL evaluator.** Tiny interpreter for the subset in §7.5. Unit-tested against edge cases (`$gte`, `timeSince`, multi-key matches).
- [ ] **FSEventStream hot reload.** Watch the active skin directory, debounce, re-apply.
- [ ] **Ship one reference skin** ("Holoscape Classic Winamp" from §13) that exercises every v2 feature at least once. Lives in `skins/examples/`.
- [ ] **XCUITest harness** that loads a test skin and asserts rendered layer properties match expected values for a given state.

Twelve follow-up cards, roughly. The first three are blocking for any chrome-skinning-driven visual change to ship.

## 16. Open questions

One genuine decision remains, and it's not urgent enough to block this design — flagging for Erik's call at scope-doc time.

**Q: Should state transitions animate only on the surface that directly reads the changed state, or cascade through composition hierarchy?**

Example: the agent errors. Both `tabBar.tab.active` and `sidebar.container` declare a state for `agentState == 3`. Both animate to red. Do they animate *simultaneously from the same `iTime`* (feels cohesive, like a whole-app mood change), or *independently with their own per-surface animation curves* (more flexibility for the skin author, but can look uncoordinated)?

My instinct: **simultaneously.** The state change is a single event; the visual response should be a single moment. But there's a real argument for independent curves if a skin wants "the tab blinks fast, the sidebar fades slow."

Not blocking this design — the implementation can default to simultaneous and add an opt-in per-surface curve later. Flagging so scope doc #5887 can make the call when we're closer to shipping.

## 17. Revision log

- **2026-04-15** — draft 1 (#5929). First-pass design after auditing the existing `SkinEngine` / `SkinDefinition` / `AppearanceConfig` / chrome views. Scoped as a v2 evolution of the existing shallow skin system, not a greenfield design.
