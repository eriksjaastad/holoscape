# Chrome v4 format — skin author's reference

`chrome` is the top-level field a v4 `skin.json` adds to declare
PNG-alpha chrome: the static window silhouette plus zero or more
animated layers composited above it. v1/v2/v3 skins continue to
work without change — the chrome field is additive and optional.

This document targets skin authors writing `.wamp` bundles or
directory-layout skins by hand. For the underlying engine design,
see `claude-specs/chrome/design.md`.

---

## Authoring modes

```json
"chrome": {
    "mode": "baked" | "composed",
    ...
}
```

### `mode: baked`

Ship a pre-rendered RGBA PNG as `chrome.image`. The engine decodes
it directly into `Base_Layer`. Authors have pixel-perfect control
over every pixel of the silhouette, including soft edges,
drop-shadows baked into the alpha channel, and non-uniform textures
across the chrome.

Required fields:

```json
"chrome": {
    "mode": "baked",
    "image": "chrome@2x.png",
    "imageOpaque": "chrome-opaque@2x.png",
    "width": 1000,
    "height": 700,
    "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 }
}
```

- `image` — bundle-relative path to a 2x-resolution RGBA PNG
  (`chrome.width * 2` × `chrome.height * 2` pixels).
- `imageOpaque` — optional Reduce Transparency variant. When the
  user toggles System Settings → Accessibility → Display → Reduce
  Transparency, the engine loads this image instead. Skip this
  field and the engine will opacify the primary image on the fly
  (alpha→255 on every non-zero pixel; silhouette preserved).
- `width` + `height` — logical (point) dimensions of the window.
- `interiorRect` — rectangle (top-left origin, logical points) where
  app content lives. Tab bar, sidebar, terminal view, etc. all
  reparent into a view pinned to this rect. The `InteriorView`
  auto-flips Y if the enclosing superview uses AppKit's bottom-left
  origin.

### `mode: composed`

Leave `chrome.image` nil and let the engine paint the silhouette at
load time from the skin's v3 surface descriptors
(`window.background`, `tabBar.container`, `sidebar.container`).
Migration path for existing v3 skins — zero repainting required.

```json
"chrome": {
    "mode": "composed",
    "width": 1000,
    "height": 700,
    "interiorRect": { "x": 40, "y": 60, "width": 920, "height": 600 }
}
```

The bake pipeline ships the result to
`~/Library/Caches/holoscape-skins/<sha>.png` so warm reloads skip
the CGContext step. Cache key is SHA-256 over manifest JSON +
referenced asset bytes — any field or asset change invalidates the
cache deterministically.

### Decision table

| Want | Use |
|---|---|
| Hand-painted chrome with soft drop shadow in alpha | `baked` |
| Existing v3 skin promoted to v4 with zero repaint | `composed` |
| Same `skin.json` renders on iOS someday | `composed` (simpler migration surface) |
| Every pixel of the chrome authored by the skin | `baked` |

---

## Animated layers

```json
"chrome": {
    "mode": "baked",
    ...
    "animations": [
        { "id": "sparks", "kind": "particle", ... },
        { "id": "leds", "kind": "ledArray", ... }
    ]
}
```

Every animated layer has:

- `id` — unique within `chrome.animations`. Appears in banner text
  when the validator rejects the layer.
- `kind` — one of `particle`, `ledArray`, `spriteAnim`, `shader`.
- `rect` — `{x, y, width, height}` in chrome-image top-left coords,
  logical points. Must fit inside `(0, 0, chrome.width,
  chrome.height)` — the validator rejects layers that extend past
  the chrome bounds.
- `z` — z-order. Must be `> 0`; `Base_Layer` occupies the implicit
  `z = 0`. Higher `z` renders above lower. Ties break by array
  order (earlier in the array renders first).
- `phaseOffset` — seconds shift added to `phaseSeconds` before the
  renderer resolves state. Default 0.
- `speedMultiplier` — multiplier on the advanced phase rate.
  Default 1. `speedMultiplier: 2` makes the animation run twice as
  fast; `0.5` halves it.
- `dataSource` — forward-compat binding. MVP accepts `"none"` and
  `"time"`. Post-MVP adds `"cpuLoad"`, `"keystrokeRate"`,
  `"paneActivity"`, etc.
- `params` — the kind-specific parameter bundle. Only the field
  matching `kind` is used; the rest must be omitted or nil.

### `kind: particle`

`CAEmitterLayer`-backed drifting / bursting particles.

```json
{
    "id": "porthole-sparks",
    "kind": "particle",
    "rect": { "x": 50, "y": 70, "width": 200, "height": 200 },
    "z": 1,
    "phaseOffset": 0,
    "speedMultiplier": 1.0,
    "dataSource": "none",
    "params": {
        "particle": {
            "birthRate": 5.0,
            "lifetime": 3.0,
            "lifetimeRange": 0.5,
            "velocity": 20.0,
            "velocityRange": 5.0,
            "emissionAngle": 1.57,
            "emissionRange": 6.28,
            "color": "#ffaa3388",
            "scale": 0.5,
            "scaleRange": 0.2,
            "image": null,
            "blendMode": "additive"
        }
    }
}
```

Every field maps 1-to-1 to a `CAEmitterCell` property:
- `birthRate` — particles per second
- `lifetime` — seconds per particle
- `velocity` — points per second
- `emissionAngle` / `emissionRange` — radians
- `color` — `#rrggbbaa` hex
- `scale` — relative size (1.0 = raw image pixels)
- `image` — bundle path to particle sprite; null fires the soft-dot
  fallback
- `blendMode` — `"normal"` | `"additive"` | `"screen"`. Additive
  uses `compositingFilter = "plusL"`.

### `kind: ledArray`

CALayer-per-cell status lights driven by patterns.

```json
{
    "id": "status-leds",
    "kind": "ledArray",
    "rect": { "x": 800, "y": 10, "width": 150, "height": 20 },
    "z": 2,
    "dataSource": "time",
    "params": {
        "ledArray": {
            "cellSize": 6.0,
            "cells": [
                { "x": 0, "y": 0, "defaultState": 0 },
                { "x": 8, "y": 0, "defaultState": 1 },
                { "x": 16, "y": 0, "defaultState": 0 }
            ],
            "palette": ["#333333", "#00ff00", "#ff0000"],
            "pattern": { "phased": { "hz": 2.0 } }
        }
    }
}
```

- `cellSize` — each cell's side length in points.
- `cells` — array of `{x, y, defaultState}`. `x` and `y` are
  layer-local coords; `defaultState` indexes `palette`.
- `palette` — hex colors. Cell's current state → palette index.
- `pattern` — one of:

| Pattern | Shape | Behavior |
|---|---|---|
| `"steady"` | `"steady": {}` | Every cell holds `defaultState` |
| `"blink"` | `{ "blink": { "hz": H, "duty": D } }` | Alternates default ↔ (default+1) at H Hz with D on-fraction |
| `"phased"` | `{ "phased": { "hz": H } }` | One cell lit at a time, cycling at H cells/sec |
| `"random"` | `{ "random": { "hz": H, "density": D } }` | Re-randomize every 1/H sec, D fraction non-default |
| `"marquee"` | `{ "marquee": { "cellsPerSecond": C, "windowSize": W } }` | W-wide window sweeps the array at C cells/sec |

Patterns are deterministic against phase seconds — same phase +
same params produce the same state set on every invocation.

### `kind: spriteAnim`

Sprite-sheet frame animation.

```json
{
    "id": "lcd-marquee",
    "kind": "spriteAnim",
    "rect": { "x": 300, "y": 10, "width": 400, "height": 24 },
    "z": 1,
    "params": {
        "spriteAnim": {
            "sheet": "assets/lcd-frames.png",
            "gridRows": 4,
            "gridCols": 8,
            "frameCount": 30,
            "fps": 12.0,
            "loop": "loop"
        }
    }
}
```

- `sheet` — bundle-relative PNG laid out as a `gridRows × gridCols`
  atlas. Frames advance left-to-right, top-to-bottom (row-major).
- `frameCount` — total frames. May be less than `gridRows * gridCols`
  (extra cells in the sheet are ignored). Validator rejects `frameCount
  > gridRows * gridCols`.
- `fps` — frames per second.
- `loop` — `"loop"` (wraps at frameCount), `"pingPong"` (reverses at
  extremes), `"once"` (holds at `frameCount - 1`).

### `kind: shader`

Built-in shader presets for ambient glows, scanlines, noise. MVP
ships three presets as CALayer-based visual approximations; a full
Metal pipeline upgrade is a future PR.

```json
{
    "id": "bottom-glow",
    "kind": "shader",
    "rect": { "x": 0, "y": 660, "width": 1000, "height": 40 },
    "z": 1,
    "params": {
        "shader": {
            "preset": "glow",
            "color": "#4488ff",
            "intensity": 0.3,
            "hz": 0.5
        }
    }
}
```

Presets:

- `"glow"` — solid color-tinted layer with additive compositing;
  opacity pulses via cosine at `hz`.
- `"scanlines"` — horizontal stripes tinted by `color`, scrolled
  vertically at `hz`.
- `"noise"` — 32×32 deterministic greyscale noise tinted by `color`,
  refreshed at `hz`.

`intensity` is the peak alpha for `glow` / `scanlines`, the overall
opacity for `noise`. `color` is `#rrggbb` or `#rrggbbaa`.

The validator rejects any preset not in `{glow, scanlines,
noise}`.

---

## Recipes (HoloscapeClassic-live)

The in-tree `HoloscapeClassic-live` reference skin exercises all
four animation kinds. Reading
`Sources/Holoscape/Resources/Skins/HoloscapeClassic-live/skin.json`
end-to-end is the fastest onboarding for a new skin author.

| Want | Kind |
|---|---|
| Drifting sparks inside a "porthole" region | `particle` |
| Status LED ladder above the tab bar | `ledArray`, pattern `marquee` or `phased` |
| Scrolling marquee ribbon | `spriteAnim` or `ledArray` pattern `marquee` |
| Soft pulsing glow behind a glass panel | `shader` preset `glow` |
| CRT-style scanlines over the whole window | `shader` preset `scanlines` |
| TV-noise static in a region | `shader` preset `noise` |
| Animated LCD text readout | `spriteAnim` with hand-authored frames |

---

## Density mode + Reduce Motion

Animated chrome respects the system density mode
(`DensityModeManager`) and the Reduce Motion accessibility
preference:

- **Density Off** — every animated layer is uninstalled; zero
  CPU/GPU cost. Returning to Full rebuilds from `chrome.animations`.
- **Density Minimal** — layers stay installed and visible but the
  clock pauses. Every renderer holds its current frame.
- **Density Full** — animations run normally.
- **Reduce Motion** — identical to Minimal semantics. Layers stay
  in the tree (accessibility prefers "designed visual with frozen
  state" over "missing element"), the clock pauses.

Animated layers are marked with `accessibilityElementsHidden` so
VoiceOver skips them entirely — the chrome is decorative.

---

## Validator errors

The `ChromeManifestValidator` runs at skin load. Fatal failures
route the skin through the rectangular fallback + surface a banner.
Non-fatal warnings load the skin as-is but flag the issue.

Fatal:

| Error | Meaning |
|---|---|
| `chrome.image is not an RGBA PNG` | Source image has no alpha channel |
| `chrome.image pixel dimensions ... don't match declared chrome size at 2x` | Declared width/height doesn't match the image (both should be at 2x backing) |
| `chrome.interiorRect falls outside chrome bounds` | `interiorRect.x + width` or `.y + height` exceeds `chrome.width` / `.height` |

Non-fatal warnings (skin still loads):

| Warning | Meaning |
|---|---|
| `chrome dimensions ... below minimum 200×100` | Sub-minimum sanity warning |
| `polygon/alpha bbox disagreement: N px` | `windowShape.polygons` disagrees with the image's alpha silhouette by more than 2 logical pixels |
| `duplicate animation id 'X'` | Two animations share the same `id` — the later one is dropped |
| `animation 'X' — rect outside chrome bounds` | `rect` extends past `chrome.width` or `.height` |
| `animation 'X' — z must be > 0` | Base_Layer owns `z = 0`; animations must composite above |
| `animation 'X' — particle.birthRate must be > 0` | — |
| `animation 'X' — spriteAnim.gridRows×gridCols < frameCount` | Grid too small for the frame count |
| `animation 'X' — ledArray.palette must be non-empty` | — |
| `animation 'X' — ledArray.cells[N].defaultState=X outside palette range [0, N)` | — |
| `animation 'X' — shader.preset 'X' unknown` | MVP ships `glow`, `scanlines`, `noise` only |
| `animation 'X' — particle image / spriteAnim sheet not found in skin bundle` | Referenced asset path missing on disk |

The per-animation errors populate
`ChromeValidationResult.disabledAnimationIDs` — those layers are
dropped at install time; the rest of the skin still renders.

---

## Template

A starter chrome template ships at
`docs/chrome-template.png` — 1000×700 RGBA with the interior rect
drawn as a semitransparent colored rectangle and cut corners
outlined. Clone it as your `chrome@2x.png` starting point, then
author the actual silhouette. A PSD version would be nice; it's
not included because no Photoshop is available in the build
environment.

---

## Further reading

- `claude-specs/chrome/design.md` — engine-side architecture
- `claude-specs/chrome/requirements.md` — every acceptance
  criterion the engine enforces
- `docs/research/chrome-risk1-transparency-findings.md` — why the
  window must be constructed borderless-from-birth (the Cocoa
  Transparency Recipe doesn't retrofit)
