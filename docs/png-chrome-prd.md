# PNG Chrome PRD — Winamp-class Skinning with Live Instrument-Panel Chrome

**Codename**: Chrome (successor to Amplify)
**Status**: proposed, replacing the `CALayer.mask` polygon approach
**Authors**: Claude Opus 4.7 (1M, local CLI) + Claude Opus 4.7 (web) — synthesized 2026-04-20 from two independent PRDs after Erik asked to merge them; revised 2026-04-20 (second pass) after Erik clarified the aesthetic target
**Date**: 2026-04-19 / 2026-04-20
**Supersedes**: shape + drag-region sections of `docs/amplify-prd.md` (chrome skinning surfaces, sprites, fonts, and `.wamp` bundles carry forward unchanged)
**Companion**: `docs/research/shaped-window-architecture-prd.md` — web Claude's independent proposal, retained for the reference-design discussion

---

## 1) Overview

A new architecture for non-rectangular, visually-distinctive, **live-animated** Holoscape windows. Instead of using `CALayer.mask` on a borderless `NSWindow`'s content view to clip a polygon shape (the Amplify v1 approach, which hit a wall — see `docs/research/shaped-window-transparency-findings.md`), **one alpha-aware compositing host owns every visible pixel of the window**, and that host is a *scene*, not a still image.

Two views, one rule, one compositor:

- **`ChromeHostView`** — layer-backed `NSView` whose sublayer tree composites a **static base layer** (RGBA PNG; alpha IS the window shape) together with zero or more **animated chrome layers** (particle emitters, LED arrays, sprite animations, shader effects, drifting glows). Every pixel rendered by this view respects the base layer's alpha. There are no interactive subviews inside it.
- **`InteriorView`** — pinned to the skin's declared `interiorRect` inside the chrome. It is the ONLY parent of app content (terminal, sidebar, tab bar, input box, session launcher). App content is inside the polygon by construction, not by masking.

This extends what Winamp, Spotify, Audion, and SoundJam do (alpha-PNG chrome) with a first-class **live compositor** — the aesthetic target is the ornate, industrial, instrument-panel chrome of the classic Winamp skin gallery (brushed metal, rivets, portholes, VU meters, LCD panels, speaker grills, blinking LEDs) **elevated with modern animation** (real-time particles, reactive LEDs, scrolling LCD text, ambient shader glows). Terminal as instrument panel, not terminal as window.

## 2) Goals

- **Cooler than Winamp.** The reference is the Y2K industrial-chrome skin gallery (brushed metal, rivets, portholes, dials, VU meters, LCDs, speaker grills). The MVP bar is: a Holoscape skin that makes someone who knew classic Winamp skins say "oh, this is the evolution of that." Animation is a first-class primitive, not post-hoc polish.
- **Actual transparency.** Cut corners / cut-out regions reveal the desktop behind, not opaque dark rectangles. Verified live on laptop.
- **Live chrome is the product.** Animated particles drifting inside a porthole, a CPU-load VU meter, blinking LEDs, scrolling LCD text, shader glows behind glass panels — these are authorable skin primitives in the MVP. The chrome moves.
- **Correctness by construction.** Adding a new subview can never break the window shape. The shape is owned by a single compositing host; the interior is owned by a single view. Animated layers render inside the chrome silhouette, never outside.
- **Fun + easy skin authoring.** Authors ship a PNG for the static base + declare animated elements in the manifest. Alpha = shape. Animated layers are a small, bounded vocabulary (particle emitter, LED array, sprite animation, shader preset) — no arbitrary scripting in MVP.
- **Graceful migration.** Existing v3 skins (HoloscapeSynthwave, AmplifyDemo) continue to work by composing a static base PNG from their existing v3 surfaces + sprites + ninepatches at load time — authors don't have to repaint. Animated layers are additive and opt-in.
- **Preserve shipped work.** Sprite sheets (individual buttons), font consumption, border/corner/shadow on individual chrome surfaces, `.wamp` bundle format, skin picker + hot reload, malformed-skin banner, fixed-size window, keyable borderless window subclass — all carry forward from Amplify v1.
- **Debuggable.** The PNG IS the source of truth for shape; animated layers are deterministic declarative descriptors. Ship a debug overlay that renders alpha values + animated-layer bounds + current frame/time so authors can see exactly what the compositor is doing.
- **First-class fidelity to the Winamp reference.** A skin author familiar with `.wsz` should feel at home authoring a `.wamp`; the live-chrome vocabulary extends it, not replaces it.

## 3) Non-Goals

- Direct `.wsz` (Winamp) import. Nice-to-have later; not MVP.
- Video chrome (MP4 / WebM backgrounds). Declarative animated layers only in MVP; video is post-MVP.
- Animated GIF chrome. GIFs introduce decode + timing ambiguities; use sprite-animation layers instead.
- Dynamic mask-image skins (the old `kind: mask` case). Post-MVP.
- Multi-window semantics (Winamp's EQ / playlist / minibrowser). Holoscape is a terminal — one main window plus the existing Reader Mode panel.
- Runtime polygon morphing for animated *shape* changes. The window silhouette is set at skin load; animated *content* happens inside the chrome silhouette or inside `InteriorView`.
- Custom skin-defined window shadows. AppKit's derived shadow from window alpha is MVP; per-skin shadows are post-MVP.
- Runtime hit-test via bezier math or alpha sampling. We keep the existing polygon point-in-polygon tester — it's fast and already works.
- Arbitrary scripting / plugin animations. Animated layers are a declarative manifest vocabulary (particle, LED, sprite-anim, shader preset). No Lua, no Maki, no JS.
- Data-source bindings to terminal state (CPU, keystroke rate, active pane) in MVP. Animations run on time / noise / simple phase clocks. Terminal-connected data sources are post-MVP.

## 4) Target Users

- **Skin authors** building instrument-panel chrome — people who see the Winamp skin gallery and want a terminal that looks like one of those panels. They ship a static base PNG, declare a handful of animated layers, watch them come alive in hot reload.
- **Skin authors** porting Winamp `.wsz` skins mentally (or literally in Phase 2) who want "paint a PNG, declare a couple LEDs, ship a skin."
- **Holoscape daily drivers** who want a visually distinctive, live terminal. A terminal that feels alive — drifting particles, pulsing LEDs, scrolling marquee text — is more engaging than a static frame, and Holoscape is a tool people look at all day.
- **Erik** specifically — this is a tool he uses every day. The bar is "cooler than Winamp." Chrome that doesn't move is not cool enough.
- **Future Claudes / contributors** working on Holoscape — the correctness-by-construction architecture means they can add new subviews without understanding the shape pipeline. The animated-layer primitives are bounded and declarative, so they can be extended without rearchitecture.

## 5) Problem Statement

Amplify v1 failed on two fronts:

**Technical failure** — used `CALayer.mask` on the content view to polygon-clip a borderless `NSWindow`. Live testing (`docs/research/shaped-window-transparency-findings.md`) confirmed the mask clips drawn content (text, sprites, window borders) correctly but does NOT clip descendant layers' `backgroundColor`. Sidebar + terminal + split-pane layers paint opaque rectangles through the mask. The observed behavior contradicts Apple's Core Animation documentation; no authoritative source explains the bypass. Two successive evenings of work produced four speculative fixes plus extensive runtime diagnostics without resolving the bug.

**Aesthetic failure** — even where Amplify v1 renders correctly, the chrome is *just colored bands*. Sidebar bg, terminal bg, tab bg — all static fills. No life. The reference — Winamp's ornate industrial-chrome gallery — has brushed metal, portholes, VU meters, blinking LEDs, weathered textures, asymmetric shapes, and (in modern hands) should have live animated surfaces. Amplify v1's surface engine is capable of painting stylized static fills; it is not capable of painting a living instrument panel.

The one-alpha-aware-compositor pattern is the only architecture every shipping shaped-window macOS app uses, and it is also the architecture every live-chrome app (media players, VJ tools, Stream Deck companion apps) uses for animation. It is not a workaround; it is the architecture for both problems at once.

## 6) Core Concept

**One alpha-aware compositing host. One interior. Inside-the-polygon by construction. Chrome moves.**

```
NSWindow (.borderless, isOpaque=false, bg=.clear, hasShadow=false)
  └── ShapedContentView  (the existing class, now a thin host)
        └── ChromeHostView  ← layer-backed NSView, fills content bounds
              │   ┌─ layer (CALayer)
              │   │    ├─ baseLayer (CALayer)
              │   │    │     contents = static RGBA chrome image
              │   │    │     alpha IS the window shape
              │   │    ├─ animLayer 0  (CAEmitterLayer / CALayer sprite / CAMetalLayer)
              │   │    ├─ animLayer 1
              │   │    ├─ …
              │   │    └─ animLayer N   (z-ordered per manifest)
              │   │   (every animLayer is clipped to baseLayer's alpha)
              │   │
              │   no interactive subviews inside ChromeHostView
              │
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

- `ChromeHostView` is the single source of truth for every chrome pixel. `baseLayer.contents` owns the window silhouette's alpha. Animated sublayers composite on top within declared bounds, each clipped so they cannot paint outside the silhouette.
- `InteriorView` is geometrically inside the chrome's opaque region. App content placed inside it can never extend into the transparent (shaped-away) region because it's constrained to `interiorRect`.
- For **convex** interiors (rounded rect, cut-corner hexagon, AmplifyDemo's octagon): `InteriorView.layer.mask` is NOT needed. The view's frame IS the clip.
- For **concave** interiors (rare — an interior with notches or holes): an `InteriorView.layer.mask` with the interior path IS set. The mask problem we hit on the full content view is bounded here — the mask only needs to clip content inside `InteriorView`, which has a deterministic shallow subtree.
- `windowShape.polygons` (existing v3 descriptor) is KEPT. It drives click-through hit testing (fast, already works) and drag regions. The manifest validator cross-checks that the polygon matches the static base image's non-transparent bounds within tolerance.

**Chrome authoring modes** (per-skin choice for the static base):

- **`chrome.mode: "baked"`** — skin author ships `chrome@2x.png` (and optionally `chrome-opaque@2x.png` for Reduce Transparency). The engine installs the image directly as `baseLayer.contents`.
- **`chrome.mode: "composed"`** — skin declares v3 surface descriptors as today; the engine composites a static base image at load time from the surfaces + sprites + ninepatches, caches it by SHA of the inputs, and installs it. Exists so HoloscapeSynthwave / AmplifyDemo migrate with zero author work.

**Animated chrome layers** are authored identically for both modes — a separate manifest array that sits on top of whichever static base the skin chose. Each layer declares its kind, bounds, and kind-specific parameters. The compositor z-orders them above the static base and clips them to the base's alpha so animations can't paint through transparent regions.

**Animated layer vocabulary (MVP)**:

1. **Particle emitter** — `CAEmitterLayer`-backed. Declarative params: birth rate, lifetime, velocity range, color, size, image (or color dot). Use cases: drifting sparks in a porthole, steam from a vent, ambient glow dust.
2. **LED array** — grid of on/off/blink cells. Declarative params: cell size, cell positions, palette, blink pattern (steady / phased / random / marquee). Use cases: status LEDs, equalizer-style ladder, "power" indicators.
3. **Sprite animation** — sequential frame playback from a sprite sheet. Declarative params: sheet path, grid, frame count, fps, loop mode (loop / ping-pong / once). Use cases: rotating dial, scrolling LCD marquee, spinning record, cassette reel, radar sweep.
4. **Shader preset** — named built-in `CAMetalLayer` shaders with declarative parameters. MVP ships 2–3: `glow` (soft pulsing luminance at a rect), `scanlines` (CRT horizontal line overlay), `noise` (animated film-grain overlay). Post-MVP can add more named presets; arbitrary user shaders stay out of scope.

All four are time-driven in MVP (phase from `CACurrentMediaTime()`), with optional per-layer `phaseOffset` and `speedMultiplier`. Reduce Motion freezes them on their starting frame without hiding them.

**Load-time bake** (composed mode): the engine walks the v3 manifest, draws each surface into a `CGContext` at the skin's nominal size, writes the result to `~/Library/Caches/holoscape-skins/<sha>.png`, and reads it back. First load ~50 ms; cache hits are free. Cache invalidates on any manifest change.

## 7) Data Model (MVP)

New/changed descriptor types in `Sources/Holoscape/Models/AmplifyDescriptors.swift`:

```swift
struct ChromeDescriptor: Codable, Equatable, Sendable {
    let mode: Mode                        // .baked | .composed
    let image: String?                    // "chrome@2x.png" — required when mode == .baked
    let imageOpaque: String?              // "chrome-opaque@2x.png" — optional Reduce Transparency variant
    let width: Int                        // logical width (= nominal window width)
    let height: Int                       // logical height
    let interiorRect: SkinRect            // required — where InteriorView sits
    let interiorPath: [Polygon]?          // optional; concave interiors only
    let animations: [ChromeAnimationLayer]?  // optional; zero-to-many animated layers

    enum Mode: String, Codable, Sendable { case baked, composed }
}

struct SkinRect: Codable, Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
}

struct ChromeAnimationLayer: Codable, Equatable, Sendable {
    let id: String                        // stable, unique within skin (for hot-reload diff)
    let kind: Kind
    let rect: SkinRect                    // bounds within chrome coordinate space
    let z: Int                            // z-order relative to siblings; base layer is z = 0
    let phaseOffset: Double?              // seconds, default 0
    let speedMultiplier: Double?          // default 1.0
    let params: Params                    // discriminated by kind

    enum Kind: String, Codable, Sendable {
        case particle, ledArray, spriteAnim, shader
    }

    // One-of: populated field matches kind. Codable decodes from a discriminator.
    struct Params: Codable, Equatable, Sendable {
        let particle: ParticleParams?
        let ledArray: LedArrayParams?
        let spriteAnim: SpriteAnimParams?
        let shader: ShaderParams?
    }
}

struct ParticleParams: Codable, Equatable, Sendable {
    let birthRate: Double                 // particles/sec
    let lifetime: Double                  // seconds
    let lifetimeRange: Double?            // ± seconds
    let velocity: Double                  // points/sec
    let velocityRange: Double?
    let emissionAngle: Double             // radians, 0 = +x
    let emissionRange: Double             // radians
    let color: String                     // hex "#rrggbbaa"
    let colorRange: String?               // optional hex for ± variance
    let scale: Double                     // 1.0 = native image size
    let scaleRange: Double?
    let image: String?                    // optional sprite; otherwise a soft dot
    let blendMode: BlendMode?             // .normal | .additive | .screen

    enum BlendMode: String, Codable, Sendable { case normal, additive, screen }
}

struct LedArrayParams: Codable, Equatable, Sendable {
    let cellSize: Double                  // square cells, logical points
    let cells: [LedCell]                  // explicit positions
    let palette: [String]                 // hex colors indexed by cell.state
    let pattern: Pattern

    struct LedCell: Codable, Equatable, Sendable {
        let x: Double, y: Double          // within rect, top-left origin
        let defaultState: Int             // palette index when pattern is idle
    }

    enum Pattern: Codable, Equatable, Sendable {
        case steady
        case blink(hz: Double, duty: Double)
        case phased(hz: Double)           // cells light in sequence
        case random(hz: Double, density: Double)
        case marquee(cellsPerSecond: Double, windowSize: Int)
    }
}

struct SpriteAnimParams: Codable, Equatable, Sendable {
    let sheet: String                     // path within bundle
    let gridRows: Int
    let gridCols: Int
    let frameCount: Int                   // may be < rows*cols if sheet is padded
    let fps: Double
    let loop: Loop

    enum Loop: String, Codable, Sendable { case loop, pingPong, once }
}

struct ShaderParams: Codable, Equatable, Sendable {
    let preset: Preset
    let color: String?                    // hex, preset-dependent
    let intensity: Double?                // 0…1, preset-dependent
    let hz: Double?                       // pulse frequency for glow/noise

    enum Preset: String, Codable, Sendable { case glow, scanlines, noise }
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
    //              Validator cross-checks it against chrome base image's non-transparent bounds.
    // dragRegions: unchanged.
    // surfaces, sprites, fonts: unchanged — they paint *inside* InteriorView when chrome is present.
}
```

**Backward compatibility**: v2/v3 skins without `chrome` continue to work as rectangular or CA-mask-polygon (whatever they declared today). `chrome: present` opts into the new pipeline. `chrome.animations` is optional; skins can ship with a purely static chrome.

## 8) Functional Requirements

### Static chrome + interior (the transparency foundation)

**FR-1 — Chrome image renders as window chrome.** When `chrome` is present, the engine installs `ChromeHostView` as the full-bounds child of `ShapedContentView`. Its `baseLayer.contents` is the chrome image (from `chrome.image` for baked skins, or the load-time bake for composed skins).

**FR-2 — Window is fixed-size.** `contentMinSize == contentMaxSize == (chrome.width, chrome.height)`. `.resizable` stripped. (Same rule Amplify v1 already ships.)

**FR-3 — Alpha = transparency.** Alpha < 1.0 pixels in the chrome image produce commensurate window transparency. Alpha == 0 pixels reveal the desktop.

**FR-4 — InteriorView owns app content.** Terminal, sidebar, tab bar, input box, session launcher, chrome bands — all parented to `InteriorView`, not to the content view directly. Layout constraints inside `InteriorView` use its bounds (treated as `(0, 0, interiorRect.width, interiorRect.height)`).

**FR-5 — InteriorView sits at `interiorRect`.** Pinned to `chrome.interiorRect` in chrome-image coordinates. For concave interiors, `InteriorView.layer.mask = CAShapeLayer(path: interiorPath)`.

**FR-6 — Hit testing uses the existing polygon.** `ShapedContentView.hitTest` continues to call `HitRegionSampler.contains(point)` against `windowShape.polygons`. Click-through outside the polygon; normal routing inside. No alpha sampling; the polygon is faster and already works.

**FR-7 — Manifest validator cross-checks polygon vs chrome image.** On skin load, the engine samples the chrome base image's alpha bounds and compares to `windowShape.polygons`' bounding box. Tolerance: ±2 logical pixels. Mismatch → `SkinWarningBanner` (Req 13.2) with a specific message naming the field that disagrees.

**FR-8 — Dragging via background.** `window.isMovableByWindowBackground = true`. The chrome image's opaque pixels ARE the background, so AppKit's "drag from bare background" requirement is satisfied wherever the chrome is opaque and no interactive subview covers. The `WindowDragOverlay` from Amplify v1 is removed.

**FR-9 — Sprite buttons, fonts, border/corner/shadow still work.** Inside `InteriorView`, existing v3 surface descriptors render exactly as today. Only the window-shape piece changes.

**FR-10 — Hot reload.** Editing the chrome image (`chrome@2x.png`), any v3 surface in a composed skin, or any entry in `chrome.animations` triggers the existing FSEventStream hot-reload path. Composed skins re-bake through the load-time pipeline; baked skins re-decode the image; animations re-diff by `id` and swap params in place without restarting running timelines where possible. Both repaint within the existing 200ms debounce.

**FR-11 — Load-time bake with SHA cache.** For `chrome.mode: composed`, the engine walks the v3 surfaces, composites them into an RGBA `CGImage` at `(chrome.width * 2, chrome.height * 2)` for @2x, SHAs the inputs, caches the result at `~/Library/Caches/holoscape-skins/<sha>.png`. Subsequent loads hit the cache. Cache respects the existing 50 MB `.wamp` cache cap.

**FR-12 — Debug overlay.** `HOLOSCAPE_PNG_CHROME_DEBUG=1` overlays (1) a semitransparent false-color rendering of the chrome image's alpha channel, (2) a red outline of `interiorRect`, (3) a green overlay of `windowShape.polygons`, (4) a yellow outline + id label for every animated layer's rect, and (5) a live clock showing current phase seconds. Skin authors toggle while iterating.

**FR-13 — Malformed chrome → graceful fallback.** Missing image, non-RGBA image, dimension mismatch with declared `width`/`height`, or `interiorRect` outside image bounds all produce a `SkinWarningBanner` (Req 13.2) and fall back to rectangular rendering with the declared v3 surface fills (i.e. the skin still loads, just without the shape).

**FR-14 — Reduce Transparency fallback.** When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true`, the engine uses `chrome.imageOpaque` if declared, otherwise renders `chrome.image` with alpha multiplied to 1.0 on the non-zero-alpha pixels (so the shape silhouette remains visible but without real transparency). Req 15.1 compliance.

**FR-15 — Reduce Motion respected.** Chrome swap on skin change does not animate when Reduce Motion is on. Animated chrome layers (FR-17 through FR-20) freeze on their starting frame. Req 15.2.

**FR-16 — HiDPI via @2x naming.** Chrome images ship at 2× by default (`chrome@2x.png`). Engine prefers @2x; falls back to `chrome.png` @1x if @2x is absent. Optional `chrome@3x.png` for ProMotion-era hardware, loaded on matching-backing-scale screens.

### Animated chrome layers

**FR-17 — Particle emitter layer.** When `chrome.animations[i].kind == .particle`, the engine installs a `CAEmitterLayer` inside `ChromeHostView` z-ordered by the layer's `z`, bounded to `layer.rect`, with parameters from `ParticleParams`. The emitter clips to `baseLayer`'s alpha so particles cannot render outside the chrome silhouette. Particles use the declared image (if any) or a procedurally-generated soft dot.

**FR-18 — LED array layer.** When `kind == .ledArray`, the engine installs a `CALayer` subtree inside `ChromeHostView` z-ordered by `z`, bounded to `layer.rect`, rendering the declared cells per `LedArrayParams.pattern`. Cell animation is driven by a single per-layer `CADisplayLink`-paced clock; `phaseOffset` and `speedMultiplier` apply. LEDs do not allocate per-frame — palette swatches and cell geometry are built once on load.

**FR-19 — Sprite animation layer.** When `kind == .spriteAnim`, the engine installs a `CALayer` whose `contents` cycles through frames of a sprite sheet using `contentsRect` UV offsets (same technique as Amplify v1 sprite state variants). Frame advancement is time-driven from `CACurrentMediaTime()`; `loop` governs behavior at the end of the sequence.

**FR-20 — Shader preset layer.** When `kind == .shader`, the engine installs a `CAMetalLayer` with a built-in shader selected by `preset`. MVP ships `glow`, `scanlines`, `noise`. Shader parameters are declarative (color, intensity, hz). Each preset has a documented parameter schema and default values. Unknown presets → FR-13 fallback (skin loads without that layer, banner shown).

**FR-21 — Animated layers clip to the chrome silhouette.** No animated layer may render a pixel where the chrome base image's alpha is 0. Implementation: a single shared `CAShapeLayer` or alpha mask derived from `baseLayer` is installed as `mask` on the animated-layer container, or each animated layer is individually masked. (Decision: single container mask — cheaper, equivalent for the convex/compound-polygon case, simpler to reason about.)

**FR-22 — Animation frame budget.** With all MVP animated layers active on a single skin, the compositor sustains 60 fps on Apple Silicon (M1 and later) without dropping frames during normal Holoscape use (typing, scrolling, pane switches). Degrades gracefully on older hardware — frame drops, not correctness loss.

**FR-23 — Density mode interaction.** `DensityMode.off` hides ALL animated chrome layers (zero CPU/GPU cost — the layers are removed from the tree, not just paused). `DensityMode.minimal` pauses animation but keeps the layers visible in their starting frame. `DensityMode.full` runs animations normally. These match existing density-mode semantics for other skin features.

**FR-24 — Manifest validator for animated layers.** On load, the engine validates (a) every `id` is unique, (b) every `rect` is inside chrome bounds, (c) kind-specific params are well-formed (e.g. `gridRows * gridCols >= frameCount`, `birthRate > 0`, `palette.count > 0`), (d) referenced sprite sheets and images exist. Any failure → FR-13 banner with the offending `id` named.

## 9) Non-Functional Requirements

- **No hardcoded absolute paths.** Asset paths are relative to the `.wamp` bundle root or directory-layout skin root.
- **No secrets in code.** N/A for this project — no credentials touch the chrome pipeline.
- **Safe file operations and validation.** Chrome image load path uses the existing `WampBundleLoader` sandbox: size cap, symlink-escape rejection, SHA-keyed cache. Decode errors never crash — they produce a logged warning + FR-13 fallback.
- **Performance budgets.**
  - First chrome bake (composed mode): ≤ 500 ms at `(chrome.width * 2, chrome.height * 2)` for a 1000×700 nominal skin.
  - Chrome cache hit: ≤ 30 ms.
  - Hit-test polygon sampling: ≤ 100 µs per point for polygons up to 64 vertices (Amplify Req 3.4 carry-forward).
  - Hot-reload debounce: existing 200 ms window honored.
  - **Animation budget**: ≤ 8 ms per frame total for animated chrome layers combined (leaves 8 ms for terminal + app content within the 16.6 ms 60 fps window). Measured via `os_signpost` region around the compositor commit phase.
  - **GPU memory**: animated layers combined stay under 64 MB texture allocation on an M1 (baseline). Particle emitters that would exceed this produce a banner and disable the layer.
- **Memory caps.** 4096×4096 maximum chrome image dimensions (44 MB decoded). Animated sprite sheets cap at 2048×2048 per sheet, four sheets per skin.
- **Swift concurrency.** `@MainActor` for `ChromeHostView`, `InteriorView`, bake pipeline integration with `SkinEngine`. Animated-layer timing runs on `CADisplayLink` (main-thread, vsync-paced). The bake itself runs on a background Dispatch queue and hops back for install.
- **Test coverage.** Unit tests for the bake pipeline (input SHA → output image bytes round-trip), `InteriorView` frame pinning, validator's polygon-vs-alpha cross-check, every animated-layer params Codable round-trip, LED pattern clock determinism (given a `phaseOffset`, assert expected states at known times). Integration tests: all existing backward-compat round-trip tests extended for the new path, plus a composed-with-animations round-trip. UI test (Mac Mini) for live transparency verification and a recorded video of each MVP skin's animations.

## 10) UX and UI Requirements

- **Authoring flow (baked mode)**: open the chrome template in any image editor (Photoshop, Figma, Pixelmator, Pillow). Paint the chrome. Save as `chrome@2x.png`. Edit `skin.json` to declare `chrome.interiorRect`, matching `windowShape.polygons`, and any `chrome.animations`. Hot reload verifies.
- **Authoring flow (composed mode)**: declare surfaces as today, add `chrome.interiorRect`, optionally declare `chrome.animations`. Engine bakes at load time.
- **Animated-layer authoring flow**: for each layer, the author writes an entry in `chrome.animations`. A worked HoloscapeClassic example ships with (a) drifting particle emitter behind the terminal porthole glass, (b) status LED ladder above the tab bar, (c) scrolling LCD marquee in the top band. Authors see their edits live via hot reload.
- **Template assets**: ship `docs/chrome-template.psd` + `docs/chrome-template.png` with the interior rect drawn as a semitransparent colored rectangle. Ship two reference skins: `HoloscapeClassic-live` (industrial-chrome panel with all four animated-layer kinds) and `HoloscapeSynthwave` (neon/gradient chrome with subtle particles + scanline shader).
- **Debug overlay**: FR-12. Essential for iterating on shape + interior rect + animation bounds.
- **First-run experience**: HoloscapeClassic ships composed with a full complement of animated layers (the "this is what cooler-than-Winamp means" demo). AmplifyDemo ships composed with a single subtle animation (glow shader). HoloscapeSynthwave migrates composed with subtle ambient particles.
- **Error surface**: Req 13.2 banner continues to be the author-facing error surface for validator failures, malformed chrome images, interior-rect mismatches, and malformed animation descriptors (FR-24).
- **Accessibility**: Reduce Motion (freeze animated layers on starting frame, skip chrome-swap animation), Reduce Transparency (opaque fallback per FR-14), Increase Contrast (keep shipped defaults — same as Amplify v1). VoiceOver and keyboard navigation: unchanged because the interactive tree lives in `InteriorView` as a standard NSView hierarchy; animated chrome layers are decorative and marked `.accessibilityHidden = true`.

## 11) Success Metrics

- **Shape works.** Cut regions of HoloscapeClassic reveal the desktop when the window is positioned over another visible window. Erik confirms via visual test on laptop, and a Mac Mini UI test does the same programmatically over a known-bright backdrop.
- **Chrome moves.** HoloscapeClassic ships with visible live animation (particles drifting in the porthole + LEDs pulsing + marquee scrolling). Screen recording captured and linked from PROGRESS.md.
- **Cool factor.** Subjective — Erik's "this is cooler than Winamp" sign-off. Non-subjective proxy: someone unfamiliar with the project, shown the reference skin gallery and then Holoscape's HoloscapeClassic, says "it's that, as a terminal."
- **Migration is clean.** HoloscapeSynthwave and AmplifyDemo render identically after migration to composed mode (modulo any new animations authors added). Backward-compat integration tests pass.
- **First third-party skin.** Someone (Erik or contributor) authors a new PNG-chrome skin end-to-end — static base + at least one animated layer — using only the format docs + template. Success = the skin loads and renders correctly without Claude's help.
- **Time to author (baked mode, static)**: blank PNG → working skin in ≤ 30 minutes for someone familiar with image editors.
- **Time to author (animated layer)**: adding one particle emitter to an existing skin ≤ 10 minutes, guided by the docs.
- **Zero CALayer-masking regressions.** No new bug reports blaming descendant opaque backgrounds painting through the shape.
- **60 fps animation budget met.** `os_signpost` traces from a 30s HoloscapeClassic session show compositor commit time ≤ 8 ms per frame on the M1 laptop.
- **New subview onboarding is a no-op.** A contributor adding a new interactive view (e.g. a status bar) adds it to `InteriorView` with standard constraints. The shape and animation pipelines require no change.

## 12) MVP Scope

In rough PR order (each is a focused, reviewable PR):

### Phase 1 — Static transparency foundation (PRs 1–9)

1. **End-to-end transparency prototype.** Minimal `ChromeHostView` installing a known-good alpha PNG on a borderless window. Laptop visual verification. Risk #1 mitigation — this gates everything else. No manifest changes yet.
2. **Data model** — `ChromeDescriptor`, `SkinRect`, `ChromeAnimationLayer` + per-kind params, `SkinDefinition` v4 fields. Tests for Codable round-trip (static + each animation kind).
3. **`ChromeHostView` + `InteriorView`** — NSView subclasses with the layer subtree. Unit tests for frame pinning, base-layer configuration, and empty-animation-list case.
4. **Load-time bake pipeline** — walk v3 surfaces, draw into CGContext, SHA cache in `~/Library/Caches/holoscape-skins/`. Tests for deterministic output + cache hit behavior.
5. **Validator** — cross-check `windowShape.polygons` vs chrome image's non-transparent bounds. Animated-layer manifest validator (FR-24). Warning banner on mismatch.
6. **`MainWindowController` chrome-mode branch** — when `chrome` is present, install `ChromeHostView` + `InteriorView`, reparent all existing subviews under `InteriorView`. Skip the old CA-mask path.
7. **Borderless + `.clear` + `hasShadow = false`** — reuse `ShapedBorderlessWindow` subclass from the investigation branch. Merge cleanly.
8. **Drag via background** — `window.isMovableByWindowBackground = true`. Remove `WindowDragOverlay`.
9. **Malformed chrome → fallback + Reduce Transparency variant** — FR-13 + FR-14.

### Phase 2 — Animated chrome layers (PRs 10–13)

10. **Particle emitter layer (FR-17)** — `CAEmitterLayer` install, clipping to chrome alpha, time-driven. Unit tests for params decode + a visual-verification integration test.
11. **LED array + sprite animation layers (FR-18, FR-19)** — shared clock infrastructure (`CADisplayLink`), per-kind renderers. Unit tests for pattern determinism.
12. **Shader preset layer (FR-20)** — `CAMetalLayer` with `glow`, `scanlines`, `noise` presets shipped as Metal shader source in the app bundle. Unit tests for preset param validation.
13. **Animation clipping + density/Reduce Motion (FR-21, FR-15, FR-23)** — single container mask derived from chrome alpha; density and Reduce Motion hooks.

### Phase 3 — Reference skins + docs (PRs 14–17)

14. **HoloscapeClassic-live** — industrial-chrome reference skin with all four animated-layer kinds active. This is the "cooler than Winamp" demo.
15. **HoloscapeSynthwave migration** — composed mode with ambient particles + scanlines shader.
16. **AmplifyDemo migration** — composed mode with a single glow shader as the minimal-animations case.
17. **Docs + template** — `docs/chrome-format.md` (skin-author reference covering static + animated primitives) + chrome template asset + worked animated-layer recipes.

### Phase 4 — Integration, verification, cleanup (PRs 18–20)

18. **Integration tests** — `BackwardCompatIntegrationTests` extended to cover composed + baked + animated paths on v4. Composed-with-every-animation-kind round-trip.
19. **Debug overlay (FR-12)** + Mac Mini UI test for live transparency + animation smoke.
20. **Delete old mask path** — `ShapedWindowController.buildMaskLayer` for contentView mask removed (moves to `InteriorView` for concave interiors only). `writeShapeDiagnostic` removed. `HitRegionSampler` kept (polygon hit testing survives). Only after all in-tree shaped skins pass on v4 with animations.

Estimate: ~10 focused days for 20 PRs (vs ~7 for the original 15 — animated layers add ~3 days).

## 13) Post-MVP

- **`.wsz` import.** Parse Winamp's ZIP bundle + `region.txt` + sprite bitmaps + `viscolor.txt` and synthesize a `.wamp`. Proof-of-concept: a subset of classic `.wsz` skins renders correctly in Holoscape as static chrome (animations added by hand).
- **Data-source bindings for animations.** LEDs driven by CPU load; particle birth rate modulated by keystroke rate; VU meter driven by terminal output throughput; marquee text from the active pane's process name. Requires a bounded event bus from terminal subsystems to the chrome compositor.
- **VU meter animated layer kind.** Classic horizontal/vertical bar meter reacting to a data source. Could also be MVP if we add data-source bindings there — otherwise it's indistinguishable from LED array + phased pattern.
- **Per-skin custom shaders.** Shader source shipped inside the `.wamp`, loaded at runtime. Sandboxed via Metal's safe subset. Authors who want truly custom effects get them.
- **Vector chrome authoring.** PDF import → load-time raster bake. Kills HiDPI @2x/@3x asset proliferation.
- **Multiple chrome states.** Separate normal / focus-lost / disabled variants for both static base and animation activity.
- **Animated GIF / video chrome background.** Full video as `baseLayer.contents` via `AVPlayerLayer`. Requires a separate renderer path and is incompatible with SHA cache semantics.
- **Per-skin shadows.** Skin ships its own shadow baked into the chrome PNG's transparent region (Winamp did exactly this). Replaces AppKit's derived-from-alpha shadow.
- **Skin gallery.** Built-in browser for community `.wamp` bundles. Requires a distribution model (e.g. github.com/holoscape/skins).
- **Dynamic mask-image skins.** The old `kind: mask` case becomes viable once the rest of the pipeline is stable.
- **Per-monitor DPI variants.** `chrome@1x.png` + `chrome@2x.png` + `chrome@3x.png` loaded per-display.
- **Runtime polygon morphing.** Animated shape changes (shaped-to-rectangular transition with an actual tween). Orthogonal to the static-shape MVP.
- **Audio-reactive animations.** If Holoscape ever hosts a media player panel, animated chrome reacts to audio FFT bins.

## 14) Constraints and Governance

- **Follow project governance and review protocol.** Every PR through `/pr` with the `code-reviewer` agent; Gate 0 scan; conventional-commit prefixes; label discipline.
- **Validation commands before completion.** `swift test` green; `./bundle.sh` succeeds; live visual verification on laptop before merging any PR that changes window rendering; animated-layer PRs also need a screen-capture in the PR description.
- **Update `PROGRESS.md` and the Amplify spec.** Each PR flips relevant `tasks.md` entries and refreshes `PROGRESS.md` if it shifts the session starting point.
- **Preserve Amplify v1 pipeline during transition.** v3 skins (polygon `windowShape`) continue to load under the legacy path until every in-tree reference skin has a v4 equivalent. No hard cutover; side-by-side coexistence through the MVP.
- **Backward-compat tests are load-bearing.** `BackwardCompatIntegrationTests` must cover: v2 directory, v2 `.wamp`, v3 directory (polygon mask), v3 `.wamp`, v4 composed directory, v4 composed `.wamp`, v4 baked directory, v4 baked `.wamp`, v4 composed with animations, v4 baked with animations. Any PR that breaks one of those blocks.
- **No silent deletes of the old path.** The old CA-mask code deletes only in the final step (#20) after live verification on all in-tree shaped skins with animations active.
- **Animated-layer vocabulary is bounded.** New animation kinds require a PRD amendment and a spec update — they are not added ad-hoc. The vocabulary is deliberately small so authors, reviewers, and future Claudes can all keep it in their head.

## 15) Risks

1. **AppKit may not honor per-pixel alpha on `ChromeHostView`'s layer.contents when used as a window background.** Low risk — this is the exact pattern every shipping shaped-window macOS app uses, documented in the Cocoa transparency recipe. **Mitigation**: first MVP PR is an end-to-end prototype that installs a known-good alpha PNG and verifies transparency before writing any of the machinery above it.
2. **Animated layers break the alpha mask.** Medium risk — if the container mask or per-layer clip isn't correctly wired, particles or sprites could paint across cut regions and defeat the whole architecture. **Mitigation**: FR-21's single-container-mask design is tested explicitly with a "particle emitter that would extend past the silhouette" fixture; screenshot assertion verifies clip.
3. **60 fps budget.** Medium risk on older hardware. **Mitigation**: FR-22 budget, `os_signpost` instrumentation on every PR touching the compositor, and FR-23 density-mode fallbacks. The M1 laptop is baseline; older Intel is best-effort.
4. **Load-time bake perf on large skins.** Low risk — 1000×700 @2x = 2000×1400 pixels, ~50 ms. **Mitigation**: SHA cache makes this a one-time cost per skin edit.
5. **Retina / scale factor drift.** Logical coords in the manifest, physical pixels in the image, hit-test coords in content view space, animated-layer coords in chrome-image space. **Mitigation**: test path covers 1×, 2×, 3× backing scale explicitly; all coordinate math uses logical units; image scale handled by `contentsScale` on layers.
6. **Author confusion with declarative animation vocabulary.** Moderate — "which kind do I use for a scrolling marquee?" **Mitigation**: docs with a decision table (marquee → spriteAnim or LED marquee pattern; drifting sparks → particle; pulsing glow behind glass → shader preset glow) plus recipes in HoloscapeClassic-live.
7. **Polygon vs PNG drift.** Author paints a PNG, forgets to update `windowShape.polygons`. Drag + hit testing misaligns visually. **Mitigation**: FR-7 cross-check validator, ±2px tolerance, warning banner names the mismatched field.
8. **Behavior differences across macOS versions.** Low. Transparency recipe stable from 10.14 on; our minimum is newer. `CAEmitterLayer` and `CAMetalLayer` both stable.
9. **`CAMetalLayer` inside `InteriorView` for the terminal shader compositor conflicting with `CAMetalLayer` in chrome shader presets.** Low. They live in disjoint view subtrees (terminal inside `InteriorView`; chrome shaders inside `ChromeHostView`). **Mitigation**: explicit test with both active — shader-preset chrome animation running while a terminal Metal shader is also running.
10. **Window shadow quality on non-rectangular chrome.** AppKit's auto-derived-from-alpha shadow is usually correct but can look halo-y on tight-fitting polygons. **Mitigation**: `hasShadow = false` + optional skin-baked shadow in the chrome PNG's transparent region (Classic-era Winamp approach). Post-MVP feature; MVP ships shadowless.
11. **GPU memory pressure from shader presets + large particle sheets.** Medium. **Mitigation**: FR-9's texture cap (64 MB) enforced at validator time, layers exceeding it disabled with a banner.
12. **Author tooling lock-in.** The Pillow generator for composed sprites is a convenience, not a requirement. **Mitigation**: explicit in docs; any image editor works.
13. **"Cool" is subjective.** HoloscapeClassic-live may ship and Erik decides it still isn't cool enough. **Mitigation**: the reference skin gallery is the benchmark; design reviews happen before PR #14 lands, not after.

## 16) Dependencies

- Existing Amplify v1 infrastructure (unchanged contracts):
  - `SkinEngine`, `WampBundleLoader`, `SkinContext`, sprite engine, font pipeline, bundle cache, skin picker, hot reload debouncer, malformed-skin banner.
  - `ShapedBorderlessWindow` subclass (canBecomeKey / canBecomeMain overrides).
  - `HitRegionSampler` (polygon point-in-polygon) — carried forward verbatim.
  - `DragRegionTracker` (drag polygons + `NSTrackingArea` management) — carried forward verbatim.
  - `isReleasedWhenClosed = false` crash fix from `fix/shape-mask-rescale-on-resize`.
- Foundation / AppKit / Core Animation only. No new third-party Swift packages.
- `NSImage` / `CGImage` / `CGImageSource` for PNG decode.
- `CGContext` for load-time bake.
- `CAEmitterLayer` for particle emitters (FR-17).
- `CADisplayLink` for vsync-paced animation clocks (FR-18, FR-19).
- `CAMetalLayer` + Metal shaders (shipped as `.metal` source in the app bundle, compiled at app build time) for shader presets (FR-20).
- `os_signpost` for performance instrumentation (FR-22 budget verification).

## 17) Open Items

1. **Coordinate origin in the manifest.** PNG-native is top-left; AppKit is bottom-left. Propose top-left in `ChromeDescriptor.interiorRect`, `SkinRect`, and all animation `rect` fields (matches how image editors think), convert internally. Document clearly and test both paths.
2. **Shadow quality on shaped chrome.** Ship `hasShadow = false` for MVP and punt baked-shadow to post-MVP. (Current plan: yes. Revisit after visual verification.)
3. **Per-density animation behavior.** FR-23 specifies `.off` removes animated layers entirely, `.minimal` freezes, `.full` animates. Confirm this is the right split vs, say, `.minimal` running animations at 15 fps. (Current plan: as spec'd. Revisit if `.minimal` feels dead.)
4. **Where does the bake happen — build time or load time?** Load time with SHA cache; matches authoring ergonomics. (Decided.)
5. **Vector chrome (PDF) source format.** Post-MVP. (Decided.)
6. **AmplifyDemo migration — composed or baked?** Ship composed for MVP; add a baked variant post-MVP as the tutorial skin. (Decided.)
7. **`windowShape` deprecation timeline.** Keep indefinitely — it's load-bearing for hit test and drag regions under both composed and baked modes. (Decided.)
8. **Test harness for "alpha actually reveals the desktop."** UI test on the Mac Mini that screenshots the app over a known-bright backdrop and samples a cut-corner pixel. Added to MVP scope as part of PR #19.
9. **What happens to `dragRegions` in the manifest under v4?** Keep as-is. `isMovableByWindowBackground` + chrome alpha covers the default case; explicit drag regions still let authors restrict drag to a specific top-band strip (Winamp title-bar style) if they want.
10. **Minimum chrome image size.** 1×1 is technically valid. Propose a minimum of 200×100 for sanity. Warn in validator if smaller.
11. **Shader preset language and surface area.** Three presets (`glow`, `scanlines`, `noise`) in MVP is deliberately small. Open question: do we ship a fourth (`crt-bend`? `chromatic-aberration`? `refraction`?) in MVP or defer? (Current plan: three in MVP, add on demand.)
12. **Animation hot-reload granularity.** Do we restart a particle emitter on any param change, or only on `rect`/`image` changes while preserving in-flight particles across `birthRate`/`color` edits? (Current plan: restart on any change in MVP for simplicity, smart-diff post-MVP.)
13. **Data-source bindings.** Post-MVP per FR-13 open-items-as-deferred-scope. Open question: should MVP ship a stubbed data-source descriptor (even if only `.none` and `.time` are implemented) so the manifest is forward-compatible? (Current plan: yes — ship the descriptor, only the `.none`/`.time` values are wired in MVP.)
