# PNG Chrome PRD — Winamp-class Skinning, Take Two

**Codename**: Chrome (successor to Amplify)
**Status**: proposed, replacing the `CALayer.mask` polygon approach
**Authors**: Claude Opus 4.7 (1M, local CLI) + Claude Opus 4.7 (web) — synthesized 2026-04-20 from two independent PRDs after Erik asked to merge them
**Date**: 2026-04-19 / 2026-04-20
**Supersedes**: shape + drag-region sections of `docs/amplify-prd.md` (chrome skinning surfaces, sprites, fonts, and `.wamp` bundles carry forward unchanged)
**Companion**: `docs/research/shaped-window-architecture-prd.md` — web Claude's independent proposal, retained for the reference-design discussion

---

## 1) Overview

A new architecture for non-rectangular, visually-distinctive Holoscape windows. Instead of using `CALayer.mask` on a borderless `NSWindow`'s content view to clip a polygon shape (the Amplify v1 approach, which hit a wall — see `docs/research/shaped-window-transparency-findings.md`), **one alpha-aware renderer owns every visible pixel of the window**.

Two views, one rule:

- **`ChromeHostView`** — single layer-backed `NSView` whose layer contents is a pre-rendered RGBA image (PNG). The image's alpha channel IS the window shape. There are no subviews inside it that can escape its alpha.
- **`InteriorView`** — pinned to the skin's declared `interiorRect` inside the chrome. It is the ONLY parent of app content (terminal, sidebar, tab bar, input box, session launcher). App content is inside the polygon by construction, not by masking.

This is what Winamp (PNG), Spotify (WebView), Audion, SoundJam, and every shipping shaped macOS app actually do. The "one alpha-aware renderer" pattern is the only one that stays correct as the app grows — every new subview goes into `InteriorView` and is automatically clipped.

## 2) Goals

- **Actual transparency.** Cut corners reveal the desktop behind, not an opaque dark rectangle. Verified live on laptop.
- **Correctness by construction.** Adding a new subview can never break the window shape. The shape is owned by a single layer; the interior is owned by a single view.
- **Fun + easy skin authoring.** Authors ship a PNG. Alpha = shape. No polygon arithmetic, no bounding-box math, no coordinate-space debates. The format is a file you open in any image editor.
- **Graceful migration.** Existing v3 skins (HoloscapeSynthwave, AmplifyDemo) continue to work by composing a chrome PNG from their existing v3 surfaces + sprites + ninepatches at load time — authors don't have to repaint.
- **Preserve shipped work.** Sprite sheets (individual buttons), font consumption, border/corner/shadow on individual chrome surfaces, `.wamp` bundle format, skin picker + hot reload, malformed-skin banner, fixed-size window, keyable borderless window subclass — all carry forward from Amplify v1.
- **Debuggable.** The PNG IS the source of truth. Ship a debug overlay that renders alpha values so authors can see exactly what the hit tester sees.
- **First-class fidelity to the Winamp reference.** A skin author familiar with `.wsz` should feel at home authoring a `.wamp`.

## 3) Non-Goals

- Direct `.wsz` (Winamp) import. Nice-to-have later; not MVP.
- Animated chrome (GIF / video backgrounds). Static PNG only.
- Dynamic mask-image skins (the old `kind: mask` case). Post-MVP.
- Multi-window semantics (Winamp's EQ / playlist / minibrowser). Holoscape is a terminal — one main window plus the existing Reader Mode panel.
- Runtime polygon morphing for animated state changes. Shape is set at skin load; animated *content* happens inside `InteriorView`.
- Custom skin-defined window shadows. AppKit's derived shadow from window alpha is MVP; per-skin shadows are v4+.
- Runtime hit-test via bezier math or alpha sampling. We keep the existing polygon point-in-polygon tester — it's fast and already works.

## 4) Target Users

- **Skin authors** porting Winamp `.wsz` skins mentally (or literally in Phase 2) who want "paint a PNG, ship a skin."
- **Holoscape daily drivers** who want a visually distinctive terminal without fighting the engine.
- **Erik** specifically — this is a tool he uses every day, and the chrome needs to not be "meh."
- **Future Claudes / contributors** working on Holoscape — the correctness-by-construction architecture means they can add new subviews without understanding the shape pipeline.

## 5) Problem Statement

Amplify v1 used `CALayer.mask` on the content view to polygon-clip a borderless `NSWindow`. Live testing (`docs/research/shaped-window-transparency-findings.md`) confirmed:

1. Every documented transparency property is correctly set (`isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, content view layer background nil, frame view layer background nil, mask installed with correct frame).
2. The mask clips drawn content (text, sprites, window borders) correctly.
3. The mask does NOT clip descendant layers' `backgroundColor`. Sidebar + terminal + split-pane layers paint opaque rectangles through the mask.
4. The observed behavior contradicts Apple's Core Animation documentation; no authoritative source explains the bypass.

Two successive evenings of work produced four speculative fixes plus extensive runtime diagnostics without resolving the bug. The architecture is fragile — every new subview is another chance to silently break shaped rendering, because correctness depends on auditing the entire ~40-layer tree for opaque descendants.

The one-alpha-aware-renderer pattern is the only architecture every shipping shaped-window macOS app uses. It is not a workaround; it is the architecture.

## 6) Core Concept

**One alpha-aware renderer. Two views. Inside-the-polygon by construction.**

```
NSWindow (.borderless, isOpaque=false, bg=.clear, hasShadow=false)
  └── ShapedContentView  (the existing class, now a thin host)
        └── ChromeHostView  ← single layer-backed NSView, fills content bounds
              │   layer.contents = RGBA image; alpha IS the window shape
              │   no interactive subviews inside it
              └── InteriorView  ← pinned to skin.chrome.interiorRect
                    │   OWNS every piece of app content
                    │   OPTIONAL: layer.mask for concave interiors only
                    ├── TabBarView
                    ├── NSSplitView
                    │     ├── sidebarContainer (SessionLauncher + SidebarView)
                    │     └── rightPane (SplitPaneManager → SplitPaneView → HoloscapeTerminalView)
                    └── InputBoxView
```

Key invariants:

- `ChromeHostView.layer.contents` is the ONLY layer whose alpha contributes to window shape. The window's overall alpha is determined pixel-by-pixel from this one layer.
- `InteriorView` is geometrically inside the chrome's opaque region. App content placed inside it can never extend into the transparent (shaped-away) region because it's constrained to `interiorRect`.
- For **convex** interiors (rounded rect, cut-corner hexagon, AmplifyDemo's octagon): `InteriorView.layer.mask` is NOT needed. The view's frame IS the clip.
- For **concave** interiors (rare — an interior with notches or holes): an `InteriorView.layer.mask` with the interior path IS set. But the MASK problem we hit on the full content view is bounded here — the mask only needs to clip content inside `InteriorView`, which has a deterministic shallow subtree.
- `windowShape.polygons` (existing v3 descriptor) is KEPT. It drives click-through hit testing (fast, already works) and drag regions. The manifest validator cross-checks that the polygon matches the chrome PNG's non-transparent bounds within tolerance.

**Authoring modes** (per-skin choice):

- **`chrome.mode: "baked"`** — skin author ships `chrome@2x.png` (and optionally `chrome-opaque@2x.png` for Reduce Transparency). The engine installs the image directly.
- **`chrome.mode: "composed"`** — skin declares v3 surface descriptors as today; the engine composites a chrome image at load time from the surfaces + sprites + ninepatches, caches it by SHA of the inputs, and installs it. Exists so HoloscapeSynthwave / AmplifyDemo migrate with zero author work.

Load-time bake: the engine walks the v3 manifest, draws each surface into a `CGContext` at the skin's nominal size, writes the result to `~/Library/Caches/holoscape-skins/<sha>.png`, and reads it back. First load ~50 ms; cache hits are free. Cache invalidates on any manifest change.

## 7) Data Model (MVP)

New/changed descriptor types in `Sources/Holoscape/Models/AmplifyDescriptors.swift`:

```swift
struct ChromeDescriptor: Codable, Equatable, Sendable {
    let mode: Mode            // .baked | .composed
    let image: String?        // "chrome@2x.png" — required when mode == .baked
    let imageOpaque: String?  // "chrome-opaque@2x.png" — optional Reduce Transparency variant
    let width: Int            // logical width (= nominal window width)
    let height: Int           // logical height
    let interiorRect: SkinRect            // required — where InteriorView sits
    let interiorPath: [Polygon]?          // optional; concave interiors only

    enum Mode: String, Codable, Sendable { case baked, composed }
}

struct SkinRect: Codable, Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
}
```

Top-level `SkinDefinition` v4 additions:

```swift
struct SkinDefinition {
    // Existing v1/v2/v3 fields unchanged — carry forward.

    // NEW v4 fields:
    let chrome: ChromeDescriptor?     // Present: shaped-window mode. Absent: rectangular as today.

    // Existing fields, behavior clarified under v4:
    // windowShape: still honored. Drives hit-test polygon + drag regions.
    //              Validator cross-checks it against chrome.image's non-transparent bounds.
    // dragRegions: unchanged.
    // surfaces, sprites, fonts: unchanged — they paint *inside* InteriorView when chrome is present.
}
```

**Backward compatibility**: v2/v3 skins without `chrome` continue to work as rectangular or CA-mask-polygon (whatever they declared today). `chrome: present` opts into the new pipeline.

## 8) Functional Requirements

**FR-1 — Chrome image renders as window chrome.** When `chrome` is present, the engine installs `ChromeHostView` as the full-bounds child of `ShapedContentView`. Its layer.contents is the chrome image (from `chrome.image` for baked skins, or the load-time bake for composed skins).

**FR-2 — Window is fixed-size.** `contentMinSize == contentMaxSize == (chrome.width, chrome.height)`. `.resizable` stripped. (Same rule Amplify v1 already ships.)

**FR-3 — Alpha = transparency.** Alpha < 1.0 pixels in the chrome image produce commensurate window transparency. Alpha == 0 pixels reveal the desktop.

**FR-4 — InteriorView owns app content.** Terminal, sidebar, tab bar, input box, session launcher, chrome bands — all parented to `InteriorView`, not to the content view directly. Layout constraints inside `InteriorView` use its bounds (treated as `(0, 0, interiorRect.width, interiorRect.height)`).

**FR-5 — InteriorView sits at `interiorRect`.** Pinned to `chrome.interiorRect` in chrome-image coordinates. For concave interiors, `InteriorView.layer.mask = CAShapeLayer(path: interiorPath)`.

**FR-6 — Hit testing uses the existing polygon.** `ShapedContentView.hitTest` continues to call `HitRegionSampler.contains(point)` against `windowShape.polygons`. Click-through outside the polygon; normal routing inside. No alpha sampling; the polygon is faster and already works.

**FR-7 — Manifest validator cross-checks polygon vs chrome image.** On skin load, the engine samples the chrome image's alpha bounds and compares to `windowShape.polygons`' bounding box. Tolerance: ±2 logical pixels. Mismatch → `SkinWarningBanner` (Req 13.2) with a specific message naming the field that disagrees.

**FR-8 — Dragging via background.** `window.isMovableByWindowBackground = true`. The chrome image's opaque pixels ARE the background, so AppKit's "drag from bare background" requirement is satisfied wherever the chrome is opaque and no interactive subview covers. The `WindowDragOverlay` from Amplify v1 is removed.

**FR-9 — Sprite buttons, fonts, border/corner/shadow still work.** Inside `InteriorView`, existing v3 surface descriptors render exactly as today. Only the window-shape piece changes.

**FR-10 — Hot reload.** Editing the chrome image (`chrome@2x.png`) or any v3 surface in a composed skin triggers the existing FSEventStream hot-reload path. Composed skins re-bake through the load-time pipeline; baked skins re-decode the image. Both repaint within the existing 200ms debounce.

**FR-11 — Load-time bake with SHA cache.** For `chrome.mode: composed`, the engine walks the v3 surfaces, composites them into an RGBA `CGImage` at `(chrome.width * 2, chrome.height * 2)` for @2x, SHAs the inputs, caches the result at `~/Library/Caches/holoscape-skins/<sha>.png`. Subsequent loads hit the cache. Cache respects the existing 50 MB `.wamp` cache cap.

**FR-12 — Debug alpha overlay.** `HOLOSCAPE_PNG_CHROME_DEBUG=1` overlays a semitransparent false-color rendering of the chrome image's alpha channel so authors can see their shape as the hit tester sees it, plus a red outline of `interiorRect` and a green overlay of `windowShape.polygons`. Skin authors toggle while iterating.

**FR-13 — Malformed chrome → graceful fallback.** Missing image, non-RGBA image, dimension mismatch with declared `width`/`height`, or `interiorRect` outside image bounds all produce a `SkinWarningBanner` (Req 13.2) and fall back to rectangular rendering with the declared v3 surface fills (i.e. the skin still loads, just without the shape).

**FR-14 — Reduce Transparency fallback.** When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true`, the engine uses `chrome.imageOpaque` if declared, otherwise renders `chrome.image` with alpha multiplied to 1.0 on the non-zero-alpha pixels (so the shape silhouette remains visible but without real transparency). Req 15.1 compliance.

**FR-15 — Reduce Motion respected.** Chrome swap on skin change does not animate when Reduce Motion is on. Req 15.2.

**FR-16 — HiDPI via @2x naming.** Chrome images ship at 2× by default (`chrome@2x.png`). Engine prefers @2x; falls back to `chrome.png` @1x if @2x is absent. Optional `chrome@3x.png` for ProMotion-era hardware, loaded on matching-backing-scale screens.

## 9) Non-Functional Requirements

- **No hardcoded absolute paths.** Asset paths are relative to the `.wamp` bundle root or directory-layout skin root.
- **No secrets in code.** N/A for this project — no credentials touch the chrome pipeline.
- **Safe file operations and validation.** Chrome image load path uses the existing `WampBundleLoader` sandbox: size cap, symlink-escape rejection, SHA-keyed cache. Decode errors never crash — they produce a logged warning + FR-13 fallback.
- **Performance budgets.**
  - First chrome bake (composed mode): ≤ 500 ms at `(chrome.width * 2, chrome.height * 2)` for a 1000×700 nominal skin. Matches Amplify v1's cold-load budget.
  - Chrome cache hit: ≤ 30 ms.
  - Hit-test polygon sampling: ≤ 100 µs per point for polygons up to 64 vertices (Amplify Req 3.4 carry-forward).
  - Hot-reload debounce: existing 200 ms window honored.
- **Memory caps.** 4096×4096 maximum chrome image dimensions (44 MB decoded). Stays under the existing 50 MB `.wamp` bundle cap with headroom for sprite assets.
- **Swift concurrency.** `@MainActor` for `ChromeHostView`, `InteriorView`, bake pipeline integration with `SkinEngine`. No new thread-hopping. The bake itself runs on a background Dispatch queue and hops back for install.
- **Test coverage.** Unit tests for the bake pipeline (input SHA → output image bytes round-trip), `InteriorView` frame pinning, validator's polygon-vs-alpha cross-check. Integration tests: all existing backward-compat round-trip tests extended for the new path. UI test (Mac Mini) for live transparency verification.

## 10) UX and UI Requirements

- **Authoring flow (baked mode)**: open the chrome template in any image editor (Photoshop, Figma, Pixelmator, Pillow). Paint the chrome. Save as `chrome@2x.png`. Edit `skin.json` to declare `chrome.interiorRect` + matching `windowShape.polygons`. Hot reload verifies.
- **Authoring flow (composed mode)**: no new work — declare surfaces as today, add `chrome.interiorRect`, engine bakes at load time.
- **Template assets**: ship `docs/chrome-template.psd` + `docs/chrome-template.png` with the interior rect drawn as a semitransparent colored rectangle. Authors replace the rectangle with real chrome art while keeping its geometry.
- **Debug overlay**: FR-12. Essential for iterating on shape + interior rect alignment.
- **First-run experience**: HoloscapeClassic ships composed (migrates v3 work automatically). AmplifyDemo ships composed. Optional: a baked-mode variant to show the "ship a PNG" workflow.
- **Error surface**: Req 13.2 banner continues to be the author-facing error surface for validator failures, malformed chrome images, interior-rect mismatches.
- **Accessibility**: Reduce Motion (skip chrome-swap animation), Reduce Transparency (opaque fallback per FR-14), Increase Contrast (keep shipped defaults — same as Amplify v1). VoiceOver and keyboard navigation: unchanged because the interactive tree lives in `InteriorView` as a standard NSView hierarchy.

## 11) Success Metrics

- **Shape works.** Cut corners of HoloscapeClassic reveal the desktop when the window is positioned over another visible window. Erik confirms via visual test on laptop, and a Mac Mini UI test does the same programmatically over a known-bright backdrop.
- **Migration is clean.** HoloscapeSynthwave and AmplifyDemo render identically after migration to composed mode. Backward-compat integration tests pass.
- **First third-party skin in baked mode.** Someone (Erik or contributor) authors a new PNG-chrome skin end-to-end using only the format docs + template. Success = the skin loads and renders correctly without Claude's help.
- **Time to author (baked mode)**: blank PNG → working skin in ≤ 30 minutes for someone familiar with image editors.
- **Zero CALayer-masking regressions.** No new bug reports blaming descendant opaque backgrounds painting through the shape.
- **New subview onboarding is a no-op.** A contributor adding a new interactive view (e.g. a status bar) adds it to `InteriorView` with standard constraints. The shape pipeline requires no change.

## 12) MVP Scope

In rough PR order (each is a focused, reviewable PR):

1. **Data model** — `ChromeDescriptor`, `SkinRect`, `SkinDefinition` v4 field. Tests for Codable round-trip.
2. **`ChromeHostView` + `InteriorView`** — NSView subclasses. Unit tests for frame pinning and layer configuration.
3. **Load-time bake pipeline** — walk v3 surfaces, draw into CGContext, SHA cache in `~/Library/Caches/holoscape-skins/`. Tests for deterministic output + cache hit behavior.
4. **Validator** — cross-check `windowShape.polygons` vs chrome image's non-transparent bounds. Warning banner on mismatch.
5. **`MainWindowController` chrome-mode branch** — when `chrome` is present, install `ChromeHostView` + `InteriorView`, reparent all existing subviews under `InteriorView`. Skip the old CA-mask path.
6. **Borderless + `.clear` + `hasShadow = false`** — reuse `ShapedBorderlessWindow` subclass from the investigation branch. Merge cleanly.
7. **Drag via background** — `window.isMovableByWindowBackground = true`. Remove `WindowDragOverlay`.
8. **Malformed chrome → fallback** — FR-13.
9. **Reduce Transparency variant** — `chrome.imageOpaque` support + FR-14 logic.
10. **HoloscapeClassic migration** — composed mode with `interiorRect`. Visual verification on laptop.
11. **AmplifyDemo migration** — same.
12. **Docs** — `docs/chrome-format.md` (skin-author reference) + chrome template asset.
13. **Integration tests** — `BackwardCompatIntegrationTests` extended to cover composed + baked paths on v4.
14. **Debug overlay** — FR-12. Optional for MVP; ship in follow-up if time pressures.
15. **Delete old mask path** — `ShapedWindowController.buildMaskLayer` for contentView mask removed (moves to `InteriorView` for concave interiors only). `writeShapeDiagnostic` removed. `HitRegionSampler` kept (polygon hit testing survives). Phased — only after both in-tree shaped skins pass on v4.

Estimate: ~7 focused days (per web Claude's sizing).

## 13) Post-MVP

- **`.wsz` import.** Parse Winamp's ZIP bundle + `region.txt` + sprite bitmaps + `viscolor.txt` and synthesize a `.wamp`. Proof-of-concept: a subset of classic `.wsz` skins renders correctly in Holoscape.
- **Vector chrome authoring.** PDF import → load-time raster bake. Kills HiDPI @2x/@3x asset proliferation.
- **Multiple chrome states.** Separate normal / focus-lost / disabled variants. Rare but some authors will want it.
- **Animated chrome.** Short MP4 or GIF background. Requires a separate renderer path.
- **Per-skin shadows.** Skin ships its own shadow baked into the chrome PNG's transparent region (Winamp did exactly this). Replaces AppKit's derived-from-alpha shadow.
- **Skin gallery.** Built-in browser for community `.wamp` bundles. Requires a distribution model (e.g. github.com/holoscape/skins).
- **Dynamic mask-image skins.** The old `kind: mask` case becomes viable once the rest of the pipeline is stable.
- **Per-monitor DPI variants.** `chrome@1x.png` + `chrome@2x.png` + `chrome@3x.png` loaded per-display.
- **Runtime polygon morphing.** Animated shape changes (shaped-to-rectangular transition with an actual tween). Orthogonal to the static-shape MVP.

## 14) Constraints and Governance

- **Follow project governance and review protocol.** Every PR through `/pr` with the `code-reviewer` agent; Gate 0 scan; conventional-commit prefixes; label discipline.
- **Validation commands before completion.** `swift test` green; `./bundle.sh` succeeds; live visual verification on laptop before merging any PR that changes window rendering.
- **Update `PROGRESS.md` and the Amplify spec.** Each PR flips relevant `tasks.md` entries and refreshes `PROGRESS.md` if it shifts the session starting point.
- **Preserve Amplify v1 pipeline during transition.** v3 skins (polygon `windowShape`) continue to load under the legacy path until every in-tree reference skin has a v4 equivalent. No hard cutover; side-by-side coexistence through the MVP.
- **Backward-compat tests are load-bearing.** `BackwardCompatIntegrationTests` must cover: v2 directory, v2 `.wamp`, v3 directory (polygon mask), v3 `.wamp`, v4 composed directory, v4 composed `.wamp`, v4 baked directory, v4 baked `.wamp`. Any PR that breaks one of those blocks.
- **No silent deletes of the old path.** The old CA-mask code deletes only in the final step (#15) after live verification on both in-tree shaped skins.

## 15) Risks

1. **AppKit may not honor per-pixel alpha on `ChromeHostView`'s layer.contents when used as a window background.** Low risk — this is the exact pattern every shipping shaped-window macOS app uses, documented in the Cocoa transparency recipe. **Mitigation**: first MVP PR is an end-to-end prototype that installs a known-good alpha PNG and verifies transparency before writing any of the machinery above it.
2. **Load-time bake perf on large skins.** 1000×700 @2x = 2000×1400 pixels of CGContext drawing, ~50 ms. Acceptable. **Mitigation**: SHA cache makes this a one-time cost per skin edit.
3. **Retina / scale factor drift.** Logical coords in the manifest, physical pixels in the image, hit-test coords in content view space. **Mitigation**: test path covers 1×, 2×, 3× backing scale explicitly; all coordinate math uses logical units; image scale handled by `contentsScale` on the layer.
4. **Author confusion with "PNG is the chrome, app lives inside InteriorView."** Moderate. **Mitigation**: docs + template + debug overlay make the mental model explicit.
5. **Polygon vs PNG drift.** Skin author paints a PNG, forgets to update `windowShape.polygons`. Drag + hit testing misaligns visually. **Mitigation**: FR-7 cross-check validator, ±2px tolerance, warning banner names the mismatched field.
6. **Behavior differences across macOS versions.** Low. Transparency recipe stable from 10.14 on; our minimum is newer.
7. **`CAMetalLayer` inside `InteriorView` for the shader compositor.** Because MetalCompositor's layer lives inside the terminal subview (which lives inside `InteriorView`), the IOSurface direct-compositor-path concern from Amplify v1's research is contained to the interior. The window shape is owned by `ChromeHostView`'s simple layer.contents, which does not use Metal. **Mitigation**: explicit test with `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS=1` + a custom shader loaded, verifying the shape is not disrupted by the shader's opaque pixels.
8. **Window shadow quality on non-rectangular chrome.** AppKit's auto-derived-from-alpha shadow is usually correct but can look halo-y on tight-fitting polygons. **Mitigation**: `hasShadow = false` + optional skin-baked shadow in the chrome PNG's transparent region (Classic-era Winamp approach). Post-MVP feature; MVP ships shadowless.
9. **Author tooling lock-in.** The Pillow generator for composed sprites is a convenience, not a requirement. Authors who don't want Python should be able to open the PNG in any image editor. **Mitigation**: explicit in docs.

## 16) Dependencies

- Existing Amplify v1 infrastructure (unchanged contracts):
  - `SkinEngine`, `WampBundleLoader`, `SkinContext`, sprite engine, font pipeline, bundle cache, skin picker, hot reload debouncer, malformed-skin banner.
  - `ShapedBorderlessWindow` subclass (canBecomeKey / canBecomeMain overrides).
  - `HitRegionSampler` (polygon point-in-polygon) — carried forward verbatim.
  - `DragRegionTracker` (drag polygons + `NSTrackingArea` management) — carried forward verbatim.
  - `isReleasedWhenClosed = false` crash fix from `fix/shape-mask-rescale-on-resize`.
- Foundation / AppKit only. No new third-party Swift packages.
- `NSImage` / `CGImage` / `CGImageSource` for PNG decode.
- `CGContext` for load-time bake.

## 17) Open Items

1. **Coordinate origin in the manifest.** PNG-native is top-left; AppKit is bottom-left. Propose top-left in `ChromeDescriptor.interiorRect` and `SkinRect` (matches how image editors think), convert internally. Document clearly and test both paths.
2. **Shadow quality on shaped chrome.** Do we ship `hasShadow = false` for MVP and punt baked-shadow to post-MVP? (Current plan: yes. Revisit after visual verification.)
3. **Per-density bake variants.** Density modes (full / minimal / off) might need distinct baked chrome (e.g. minimal mode drops border/shadow art). (Current plan: density-mode variants are post-MVP; MVP bakes once per skin, uses it across all density modes.)
4. **Where does the bake happen — build time or load time?** Build time: zero launch cost, but every palette tweak requires a rebuild. Load time: slower first load, aligns with the sprite-generator flow, supports hot reload end-to-end. **Recommendation: load-time with SHA cache**; matches authoring ergonomics.
5. **Should `chrome.image` support vector formats?** PDF at author time + load-time raster bake resolves the HiDPI asset-proliferation question. Adds a Core Graphics PDF dependency. **Recommendation: post-MVP.**
6. **AmplifyDemo migration — composed or baked?** Composed is zero-author-work. Baked is a nicer demo of the "ship a PNG" workflow. **Recommendation: ship composed for MVP; add a baked variant post-MVP as the tutorial skin.**
7. **`windowShape` deprecation timeline.** Keep polygon `windowShape` loadable in v4, warn on use, remove in v5. OR keep indefinitely because polygon hit testing is still the canonical fast path. **Recommendation: keep indefinitely — it's load-bearing for hit test and drag regions under both composed and baked modes.**
8. **Test harness for "alpha actually reveals the desktop."** Can't assert in headless XCTest. **Plan**: one UI test on the Mac Mini that screenshots the app over a known-bright backdrop and samples a cut-corner pixel. Deferred to post-MVP unless it blocks Erik's confidence.
9. **What happens to `dragRegions` in the manifest under v4?** Keep as-is. `isMovableByWindowBackground` + chrome alpha covers the default case; explicit drag regions still let authors restrict drag to a specific top-band strip (Winamp title-bar style) if they want.
10. **Minimum chrome image size.** 1×1 is technically valid. Propose a minimum of 200×100 for sanity. Warn in validator if smaller.
