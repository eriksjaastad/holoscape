# Shaped-Window Chrome Architecture — PRD

**Author**: web Claude (Opus 4.7 1M), 2026-04-20
**Status**: Proposal for comparison against the local CLI's draft.
**Context**: 6+ hours hunting a transparency bug on `fix/shaped-window-transparency`.
The current architecture is provably fragile; every new subview is another chance
to silently break shaped rendering. Erik asked for a write-up so two independent
proposals can be compared before choosing a direction.

---

## Problem

Today's architecture:

```
NSWindow(.borderless, isOpaque=false, bg=.clear)
  └── ShapedContentView (wantsLayer=true, layer.mask = CAShapeLayer)
        ├── WindowDragOverlay
        ├── 4× chrome bands (wantsLayer=true)
        ├── NSSplitView
        │    └── sidebarContainer (layer.bg = opaque navy)
        │    └── SplitPaneView(s) → SwiftTerm.MacTerminalView (layer.bg = opaque black)
        └── TabBarView
```

The CAShapeLayer mask on `contentView.layer` *should* clip every descendant's
composited output to the polygon path. In practice, at least one of ~40 layer-
backed descendants silently defeats the mask and the cut corners render opaque.

**Why the recipe is wrong for this app**, not just buggy: every future subview
(minimap, preview pane, new widget, a SwiftTerm update that adds an MTKView
backing) is another chance to reintroduce the problem. We don't want a design
where correctness depends on a whole-tree layer audit.

---

## Proposed architecture

**"One alpha-aware renderer owns every visible pixel."** This is what Winamp,
Audion, SoundJam, Spotify's mini player, and every shipping shaped macOS app
do — whether via a PNG, a WebView, or a single custom `drawRect`.

```
NSWindow(.borderless, isOpaque=false, bg=.clear)
  └── ChromeHostView                    ← single layer-backed NSView
        │   renders the full skin chrome; alpha channel IS the window shape
        │   no subviews that escape its alpha
        └── InteriorView                ← pinned to the skin's interiorRect
              │   has its own CALayer mask if the interior is concave
              ├── TabBar
              ├── Sidebar
              └── Terminal / SplitPane
```

Key properties:
- `ChromeHostView` either displays a pre-rendered PNG with alpha (skin authors
  ship it) or renders its chrome programmatically into a single CGContext
  (generated at skin load time from the v3 manifest).
- `InteriorView` is the ONLY parent of app content. It sits inside the polygon
  by construction, not by masking — so app content can never extend into the
  cut-corner region.
- No mask on the window's content view. The `CAShapeLayer` path moves to an
  `InteriorView.layer.mask` only when the interior shape is concave (rare).
  For convex interiors (rounded rect, cut-corner hexagon) no mask is needed.

The mask-fragility problem disappears because there's only one layer that
participates in window-shape alpha: `ChromeHostView.layer.contents`.

---

## Manifest changes

Keep `windowShape.polygons` (still drives click-through sampling and drag regions).

Add to the v3 skin manifest:

```json
{
  "chrome": {
    "image": "chrome@2x.png",          // required for shaped skins
    "interiorRect": {                   // required
      "x": 12, "y": 48,
      "width": 976, "height": 612
    },
    "interiorPath": [                   // optional; concave interiors only
      [{"x":0,"y":0}, {"x":976,"y":0}, ...]
    ]
  }
}
```

For gradient/sprite-based skins that don't ship a pre-baked chrome PNG, the skin
engine composites one at load time from the existing surfaces + ninepatch +
sprite descriptors, caches the result by SHA of the inputs, and hands the
cached bitmap to `ChromeHostView`.

---

## Migration

Phase 1 — build the new path without removing the old:
1. Introduce `ChromeHostView` and `InteriorView`, opt in per-skin via a new
   manifest flag `chrome.mode: "baked"` vs default `"composed"` (the current path).
2. `HoloscapeClassic` and `AmplifyDemo` gain `chrome@2x.png` + `interiorRect`;
   bake their current generator output through the existing sprite pipeline.
3. `MainWindowController.applyWindowShape` gains a branch: baked-mode skins
   skip `contentView.layer.mask` entirely and route children under `InteriorView`.

Phase 2 — delete the old path:
4. Once both in-tree shaped skins run on `baked`, remove the `.mask` installation,
   the per-subview opaque-layer hunt, and `writeShapeDiagnostic`.
5. `ShapedWindowController.buildMaskLayer` stays for optional concave interiors,
   but its primary consumer becomes `InteriorView` not the window content view.

Phase 3 — deprecate `composed`:
6. Rectangular-only skins keep the current simple path (no reconstruction, no
   ChromeHostView). `composed` shaped-mode is removed from v4 onward.

---

## What breaks

- **v2 skins without pre-baked chrome**: shaped mode unavailable. This is fine —
  it doesn't work today anyway.
- **Density modes + shaped chrome**: the baked PNG includes chrome-band art.
  Density transitions need per-density variants (`chrome-full@2x.png`,
  `chrome-minimal@2x.png`). Acceptable; it's already the case that Classic and
  AmplifyDemo ship static-density sprites.
- **Hot-reload UX**: editing a gradient color means re-baking the chrome PNG.
  Current hot-reload already debounces 200ms; the bake step adds ~20–50ms per
  reload. Barely noticeable, and only when editing a shaped skin.
- **Custom Metal shader overlay**: `MetalCompositor`'s `CAMetalLayer` must sit
  inside `InteriorView`, not at the window root. Already the intended location.
- **Dynamic Reduce-Transparency**: ship a second baked variant
  (`chrome-opaque@2x.png`) and pick at load time based on
  `accessibilityDisplayShouldReduceTransparency`. One extra asset per skin.

---

## What stays unchanged

- `HitRegionSampler` + click-through polygon testing.
- `DragRegionTracker` + drag-region polygons.
- Feature flag `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS`.
- `ShapedWindowController.reconstructWindow` (still needed for titled↔borderless
  transitions on skin switch — but now the new window starts with a much simpler,
  deterministic subtree).
- v2 rectangular skins: zero behavior change.
- `isReleasedWhenClosed = false` crash fix from the other branch: still needed,
  merges cleanly.

---

## Non-goals

- Dynamic mask-image skins (`kind: mask` in the manifest) — still post-MVP.
- Per-skin shadow authoring — AppKit's default shadow (ordered off by the
  `hasShadow = false` path) is what we want for shaped windows; a custom shadow
  is a v4+ ask.
- Runtime polygon morphing (e.g. for animated state changes). Shape is set at
  skin load; animated *content* happens inside `InteriorView`.

---

## Risks

1. **Raster chrome on HiDPI**. Ship `@2x` (and `@3x` on ProMotion-era hardware
   if we care). At load time, prefer `chrome@2x.png` over `chrome.png`. Known
   solvable; matches existing sprite-sheet practice.
2. **Live window resize** + raster chrome stretches unattractively. Shaped
   windows are already fixed-size per card #6037 (`contentMinSize ==
   contentMaxSize == nominal`). Non-issue unless we lift that constraint.
3. **SwiftTerm background**: the terminal paints opaque black inside
   `InteriorView`. That's the intended behavior — the terminal is the app
   content and should be fully opaque. The shape boundary is owned entirely by
   `ChromeHostView`, which is unrelated to anything SwiftTerm does.
4. **Window shadow quality on non-rectangular chrome**: AppKit's auto-derived
   shadow from window alpha is usually correct for shaped PNGs, but can look
   halo-y. Fallback: `hasShadow = false` + skin ships its own shadow baked into
   the chrome PNG's transparent region. Classic-era Winamp did exactly this.
5. **Accessibility**: voice-over and keyboard navigation still work because the
   interactive tree lives in `InteriorView` — standard NSView hierarchy. Unlike
   the mask approach, nothing about AX routing depends on CA.

---

## Size estimate

| Work | Days |
| --- | --- |
| `ChromeHostView` + `InteriorView` classes | 1 |
| Manifest parsing for `chrome.image` + `interiorRect` | 0.5 |
| Load-time bake path (compose from current surfaces+sprites for skins without a shipped PNG) | 1.5 |
| `MainWindowController.applyWindowShape` new branch + wiring | 1 |
| Migrate AmplifyDemo + HoloscapeClassic assets | 1 |
| Test updates (`ShapedWindowControllerTests` → `InteriorClippingTests` + bake-pipeline tests) | 1 |
| Delete old mask path + diagnostic | 0.5 |
| Spec / PRD / manifest docs | 0.5 |
| **Total** | **~7 focused days** |

---

## Open questions

1. **Bake at build time or load time?** Build-time: zero launch cost, but every
   palette tweak requires rerunning the asset pipeline. Load-time: slower first
   load, but aligns with the existing sprite-generator flow. **Recommendation:
   load-time with SHA-keyed cache in `~/Library/Caches/holoscape-skins/`.**
2. **Should `chrome.image` support vector (SVG, PDF)?** Kills the HiDPI concern.
   Adds a dependency (no native SVG in AppKit — would need WebKit or a PDF path
   via Core Graphics). **Recommendation: PDF for v4 authoring workflow, still
   baked to raster at load.**
3. **Do we keep `windowShape.polygons` when we have `chrome.image`?** The polygon
   is still needed for click-through sampling (cheaper than alpha-testing the
   PNG per event). **Keep both; the manifest validator cross-checks that the
   polygon matches the PNG's non-transparent bounds within tolerance.**

---

## Recommendation

Ship this as Amplify Task 22 (new card). Execute the 7-day plan on a feature
branch. Merge the current `fix/shaped-window-transparency` work only for the
`hasShadow=false`, `isReleasedWhenClosed=false`, and `ShapedBorderlessWindow`
subclass changes — those stay useful in the new architecture. Drop the
`contentView.layer.backgroundColor = nil`, the `applyWindowSurfaces` reorder,
and the `writeShapeDiagnostic` infrastructure — they're all symptom-chasing
for the old architecture.

The CAShapeLayer-mask approach is theoretically correct and documented to
work — but the gap between "works in a 5-line Stack Overflow demo" and "works
in a 40-layer-deep production view hierarchy" has eaten six hours and would
eat more on every future view addition. The one-renderer pattern isn't a
workaround; it's the architecture every shipping shaped-window app uses,
because it's the only one that stays correct as the app grows.
