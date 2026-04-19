# Amplify Skin Format

Reference documentation for authoring Holoscape skins. Companion to `docs/amplify-prd.md` (the feature spec) and `claude-specs/amplify/` (requirements + design + tasks).

## Overview

A Holoscape skin is a directory (or a `.wamp` ZIP of that directory) containing a `skin.json` manifest plus any referenced image assets. Holoscape loads it at launch and on live config change. Three manifest generations coexist:

- **v1** — flat color fields, original format. Still loads; chrome appearance is mostly hardcoded around it.
- **v2** — adds the `surfaces` dictionary. Per-chrome-surface fills, borders, corners, shadows, fonts, animation curves, state variants.
- **v3 (Amplify)** — adds `windowShape`, `dragRegions`, sprite metadata on `image` fills, and expands the surface catalog with interactive-state + window-level surfaces. Every v3 field is additive and optional; a v3 manifest with no v3-specific fields renders identically to its v2 form.

The `version` string in `skin.json` is advisory — the loader feature-tests fields rather than gating on the string.

## Bundle layout

```
MySkin/
  skin.json                              Manifest (required)
  assets/
    *.png                                Images referenced from the manifest
    *.ninepatch.json                     9-slice sidecars, one per image that needs one
    fonts/
      *.ttf                              Registered automatically at load
      *.otf
```

The `.wamp` form is a ZIP of the above with `.wamp` as the file extension. Two rules:

1. **No symlinks in the archive.** `WampBundleLoader` skips all non-file ZIP entries; a symlink ships as nothing.
2. **No paths outside the root.** Absolute paths (`/etc/...`), parent traversal (`../`), and URL schemes (`file://`, `http://`) are rejected. `assertPathResolvesInside` runs post-write and catches any symlink-escape attempt that slipped through the string gate.

Size caps: 50 MB per asset, 50 MB total bundle. Oversized bundles are rejected with a diagnostic naming the offender.

### Directory vs `.wamp` precedence

Inside each of the user (`~/.holoscape/skins/`) and bundled (`Bundle.main/Resources/Skins/`) roots, a directory-layout skin wins over a `.wamp` of the same name. User-installed skins win over bundled skins of the same name. See `SkinEngine.resolveSkinLocation` for the exact order.

## `skin.json` structure

```json
{
  "version": "3.0",
  "name": "My Skin",
  "author": "You",
  "description": "One-liner shown in the picker.",
  "surfaces": { ... },
  "windowShape": { ... },
  "dragRegions": [ ... ]
}
```

All fields are optional. `version` defaults to `"1.0"` when absent.

## Surface descriptors

Every entry in `surfaces` maps a dotted `SurfaceKey` to a `SurfaceDescriptor`:

```json
"tabBar.tab.active": {
  "fill":    { "kind": "color", "value": "#ff4dd1" },
  "border":  { "color": "#000000", "width": 1.0 },
  "corner":  6.0,
  "padding": { "top": 4, "right": 8, "bottom": 4, "left": 8 },
  "shadow":  { "color": "#000000", "opacity": 0.4, "blur": 6, "offsetX": 0, "offsetY": 2 },
  "font":    { "family": "Helvetica", "size": 12, "weight": "bold" },
  "text":    { "color": "#ffffff" },
  "animation": { "default": { "duration": 0.15, "curve": "easeOut" } },
  "states":  [ ... ]
}
```

Each field is optional. Missing fields fall back to the built-in defaults (the pre-skinning hardcoded values).

### `fill`

Discriminated union with three variants:

| kind       | Shape                                                                                          |
|------------|------------------------------------------------------------------------------------------------|
| `color`    | `{ "kind": "color", "value": "#RRGGBB" }` or `#RRGGBBAA`                                       |
| `image`    | `{ "kind": "image", "path": "assets/x.png", "tile": "stretch\|tile\|ninepatch", "sprite": ... }` |
| `gradient` | `{ "kind": "gradient", "direction": "vertical\|horizontal", "stops": [ {offset,color}... ] }`  |

`tile` defaults to `"stretch"`. `"ninepatch"` requires a sibling `<image>.ninepatch.json` sidecar (see below). `sprite` is v3-only — see Sprite sheets.

Gradient stops are `[0.0, 1.0]` offsets with hex colors. Stops are rendered in array order.

### `border`, `corner`, `padding`, `shadow`

- `border`: `{ "color": "#hex", "width": 1.0 }`.
- `corner`: either a single number (uniform radius) or a 4-element array `[topLeft, topRight, bottomRight, bottomLeft]`.
- `padding`: `{ "top", "right", "bottom", "left" }` in points.
- `shadow`: `{ "color", "opacity", "blur", "offsetX", "offsetY" }`. Only applied where the chrome view opts in to shadows.

### `font`

```json
{ "family": "Menlo", "size": 13, "weight": "regular" }
```

`weight` is one of `"ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"`. Custom fonts ship under `assets/fonts/` and are registered with `CTFontManager` in `.process` scope on skin load; the matching `unregisterFonts` call on unload keeps the scope symmetric so fonts don't leak between skin switches.

### `text`

```json
{ "color": "#hex", "shadow": { ... } }
```

Applies to labels painted by views that consume `resolved.text`. Not every chrome surface renders text — check the surface's role before authoring.

### `animation`

```json
{ "default": { "duration": 0.15, "curve": "easeOut" },
  "fill":    { "duration": 0.10, "curve": "linear" },
  "corner":  { "duration": 0.20, "curve": "spring" } }
```

`curve` values: `"linear"`, `"easeIn"`, `"easeOut"`, `"easeInOut"`, `"spring"`. Per-property keys override `default`.

## Ninepatch sidecars

A `ninepatch` tile mode requires a sibling JSON sidecar named `<image>.ninepatch.json`:

```json
{ "stretchX": [8, 24], "stretchY": [8, 24] }
```

Both ranges are two-element `[start, end]` pixel bands identifying the stretchable region. Everything outside those ranges renders at 1:1 (the corners). Zero-width bands are treated as invalid — the renderer falls back to `stretch` mode and logs a warning.

## Sprite sheets

Attach `sprite` metadata to an `image` fill to turn the PNG into a state-indexed atlas:

```json
"sessionLauncher.button.normal": {
  "fill": {
    "kind": "image",
    "path": "assets/launcher-button.png",
    "tile": "stretch",
    "sprite": {
      "cellWidth": 24,
      "cellHeight": 24,
      "rows": 1,
      "cols": 3,
      "stateMap": {
        "normal":  { "row": 0, "col": 0 },
        "hover":   { "row": 0, "col": 1 },
        "pressed": { "row": 0, "col": 2 }
      }
    }
  }
}
```

The shared sheet is assigned to the layer's `contents` once at load. State transitions mutate `contentsRect` only — no per-state NSImage crop, no CGImage reallocation on the hot path. Missing state keys fall back to `normal`; a sprite with neither the requested state nor `normal` renders the full sheet in stretch mode.

### Sprite states

The `stateMap` keys come from this enum; any other key is ignored with a warning:

| Name       | Meaning                                              |
|------------|------------------------------------------------------|
| `normal`   | Idle; default state.                                 |
| `hover`    | Cursor is inside the interactive region.             |
| `pressed`  | Mouse button is down.                                |
| `active`   | Element represents the currently-foregrounded entity. |
| `disabled` | Control is unavailable.                              |
| `focused`  | Element has keyboard focus.                          |
| `selected` | Element is part of a current selection.              |

Resolution priority on interactive chrome: `pressed > hover > active > normal`.

## State variants

Conditional overrides within a `SurfaceDescriptor`:

```json
"sidebar.row.indicator": {
  "fill": { "kind": "color", "value": "#1aff8c" },
  "states": [
    {
      "name": "connecting",
      "match": { "channelConnectionState": 1 },
      "fill": { "kind": "color", "value": "#ffcc00" }
    },
    {
      "name": "disconnected",
      "match": { "channelConnectionState": 2 },
      "fill": { "kind": "color", "value": "#ff3b30" }
    }
  ]
}
```

States are CSS-cascade: evaluated in array order, last match wins. A variant only supplies the fields it overrides — unspecified fields fall through to the surface defaults.

### Match expressions

`match` is a JSON object keyed by `ReactiveUniformSnapshot` field name. Values take three forms:

- **Scalar** — `{ "channelConnectionState": 1 }` shorthand for `$eq 1`.
- **Operator dict** — `{ "spriteState": { "$gte": 1, "$lt": 3 } }`. Operators: `$eq`, `$ne`, `$lt`, `$lte`, `$gt`, `$gte`.
- **timeSince dict** — `{ "iTimeAgentStateChange": { "$lt": 2.0 } }` (nested form). Used for "during the first N seconds after X changed" rules.

Multiple keys in one `match` combine with logical AND. Mixing `$`-prefixed and bare keys in the same value is rejected as malformed.

## Surface catalog

All `SurfaceKey` raw values currently recognized. Unknown keys in a manifest are logged and ignored — future additions don't break older builds.

### v2 surfaces

| Key                          | Painted by                                |
|------------------------------|-------------------------------------------|
| `window.titleBar`            | Main window title bar band                |
| `window.background`          | Main window content backing               |
| `tabBar.container`           | Tab strip background                      |
| `tabBar.tab.active`          | Foregrounded tab                          |
| `tabBar.tab.idle`            | Connected-but-quiet tab                   |
| `tabBar.tab.permission`      | Tab awaiting agent permission prompt      |
| `tabBar.tab.normal`          | Baseline inactive tab                     |
| `tabBar.tab.unreadMarker`    | Small dot overlay for unread activity     |
| `sidebar.container`          | Sidebar background                        |
| `sidebar.row.normal`         | Inactive sidebar row                      |
| `sidebar.row.selected`       | Selected sidebar row                      |
| `sidebar.row.hover`          | Hovered sidebar row                       |
| `sidebar.row.indicator`      | Connection-state dot next to row label    |
| `sidebar.sectionHeader`      | Section divider label (PROJECTS, etc.)    |
| `inputBox.container`         | Input box outer frame                     |
| `inputBox.field`             | Input text field background               |
| `inputBox.placeholder`       | Placeholder string color                  |
| `sessionLauncher.container`  | Session launcher bar background           |
| `sessionLauncher.row`        | Individual launcher menu row              |
| `splitPane.divider`          | Drag bar between split panes              |
| `terminalContainer.padding`  | Padding band around the terminal view     |
| `settings.panel`             | Settings window background                |
| `dialog.container`           | Modal/alert dialog frame                  |

### v3 (Amplify) additions

| Key                                    | Painted by                                     |
|----------------------------------------|------------------------------------------------|
| `tabBar.tab.hover`                     | Hovered tab                                    |
| `tabBar.tab.pressed`                   | Tab with mouseDown active                      |
| `sidebar.row.pressed`                  | Pressed sidebar row                            |
| `sessionLauncher.button.normal`        | Launcher refresh button, idle                  |
| `sessionLauncher.button.hover`         | Launcher refresh button, cursor inside         |
| `sessionLauncher.button.pressed`       | Launcher refresh button, mouseDown active      |
| `readerPanel.titleBar`                 | Reader Mode panel title bar                    |
| `readerPanel.background`               | Reader Mode panel content backing              |
| `readerPanel.closeButton.normal`       | Reader close button, idle                      |
| `readerPanel.closeButton.hover`        | Reader close button, cursor inside             |
| `readerPanel.closeButton.pressed`      | Reader close button, mouseDown active          |
| `window.shape`                         | Window-shape-tied fill (reserved)              |
| `window.dragHandle`                    | Skin-authored drag-handle visual               |

## Window shape (v3)

Declares a non-rectangular window. Activated only when the `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` env flag is on.

```json
"windowShape": {
  "kind": "polygons",
  "polygons": [
    {
      "points": [
        { "x":   0, "y":   0 },
        { "x": 800, "y":   0 },
        { "x": 800, "y": 600 },
        { "x":   0, "y": 600 }
      ]
    }
  ]
}
```

Coordinates are in content-view points, origin bottom-left (AppKit convention). Each polygon needs at least 3 vertices; polygons with fewer are dropped with a warning. `ShapedWindowController` reconstructs the window borderless and installs a `CAShapeLayer` mask built from the union of declared polygons.

`kind: "mask"` is reserved for PNG-alpha-mask shapes and currently rejected at validate time with `"kind: mask is post-MVP; ignoring shape"`. Decodable so v3+ manifests round-trip; not yet rendered.

## Drag regions (v3)

Polygon regions that invoke `window.performDrag(with:)` on `mouseDown`. Required for a borderless shaped window to remain draggable from its skin-painted chrome.

```json
"dragRegions": [
  {
    "polygons": [
      { "points": [ {"x":0,"y":570}, {"x":800,"y":570}, {"x":800,"y":600}, {"x":0,"y":600} ] }
    ],
    "modifier": "none"
  },
  {
    "polygons": [
      { "points": [ {"x":0,"y":0}, {"x":800,"y":0}, {"x":800,"y":40}, {"x":0,"y":40} ] }
    ],
    "modifier": "command"
  }
]
```

`modifier` values: `"none"` (default — any `mouseDown` starts a drag) or `"command"` (requires Command held at `mouseDown`). Unknown modifiers fall back to `"none"`.

Polygons with fewer than 3 vertices are dropped with a warning. A descriptor whose polygons are all invalid is omitted. Regions under 44×44 pts emit an HIG warning (touch-target minimum); the region still installs — the warning is advisory.

## Failure modes

`Requirement 13 Graceful Degradation` — a broken skin degrades rather than crashing Holoscape. The engine logs exactly one diagnostic per failure class, naming the offending path or index.

| Failure                                           | Behavior                                                                                       |
|---------------------------------------------------|------------------------------------------------------------------------------------------------|
| Malformed `skin.json`                             | Skin dropped from picker, parse error logged, previously-active skin stays live                |
| Invalid `windowShape`                             | Other skin features apply normally; window reverts to rectangular; 5-second banner on window   |
| Missing or unregisterable font                    | Other features apply; affected labels fall back to system font; one warning per missing font   |
| Missing sprite-sheet image                        | Surface falls back to its color fill (or built-in default); warning names the missing path     |
| Malformed `dragRegions` entry (<3 vertices, etc.) | Offending descriptor dropped; other descriptors apply; warning names the offending array index |
| Oversized asset or bundle                         | Bundle rejected at load; diagnostic names the offender and the cap                             |
| Sandbox violation in `.wamp` entry path           | Bundle rejected at load; diagnostic names the offending archive member path                    |

Banner text is VoiceOver-readable and skips fade animation when Reduce Motion is set.

## Worked example: HoloscapeSynthwave

Ships under `Sources/Holoscape/Resources/Skins/HoloscapeSynthwave/`. v2 manifest — no Amplify-specific fields, but exercises gradients, ninepatch, and state variants end-to-end.

```json
{
  "version": "2.0",
  "name": "Holoscape Synthwave",
  "surfaces": {
    "window.background": {
      "fill": { "kind": "gradient", "direction": "vertical",
                "stops": [ {"offset":0.0,"color":"#1a0933"},
                           {"offset":1.0,"color":"#3d1a5e"} ] }
    },
    "tabBar.container": {
      "fill": { "kind": "gradient", "direction": "horizontal",
                "stops": [ {"offset":0.0,"color":"#0d4d6b"},
                           {"offset":1.0,"color":"#1a9fd4"} ] }
    },
    "sidebar.container": {
      "fill": { "kind": "image", "path": "assets/sidebar-tile.png", "tile": "ninepatch" }
    },
    "sidebar.row.indicator": {
      "fill": { "kind": "color", "value": "#1aff8c" },
      "states": [
        { "name": "connecting",   "match": { "channelConnectionState": 1 },
          "fill": { "kind": "color", "value": "#ffcc00" } },
        { "name": "disconnected", "match": { "channelConnectionState": 2 },
          "fill": { "kind": "color", "value": "#ff3b30" } }
      ]
    }
  }
}
```

Sidecar at `assets/sidebar-tile.ninepatch.json`:

```json
{ "stretchX": [8, 24], "stretchY": [8, 24] }
```

Both the directory and `.wamp` forms ship in the app bundle. The `.wamp` is produced by `tools/package_synthwave.sh`.

## Packaging

```bash
tools/package_synthwave.sh
```

Removes any previous `HoloscapeSynthwave.wamp`, then creates a reproducible ZIP of the `HoloscapeSynthwave/` directory next to it. `-X` strips extra file metadata so bundles hash identically across machines. Safe to re-run.

Wire into a build step when the directory-layout form is the source of truth and the `.wamp` is a derived artifact.
