# Requirements Document: PNG-Alpha Chrome with Animated Compositing Host

## Introduction

Holoscape is a macOS terminal application written in Swift 6 / AppKit. Amplify v1 shipped the full v3 skin pipeline (sprite sheets, `.wamp` bundles, font consumption, border/corner/shadow, malformed-skin banner, fixed-size keyable borderless windows, polygon hit testing, drag regions) on `main`, but its `CALayer.mask`-based shape approach did not produce actual per-pixel window transparency at cut corners — descendant layers' `backgroundColor` bypassed the ancestor mask. See `docs/research/shaped-window-transparency-findings.md` for the investigation.

This document specifies the successor architecture: a **PNG-alpha compositing host** that owns every visible pixel of a shaped Holoscape window, combined with a first-class **live animated chrome compositor** that renders particle emitters, LED arrays, sprite animations, and Metal shader presets on top of a static base image. The aesthetic target, stated explicitly by Erik, is "cooler than Winamp" — the industrial-chrome Y2K skin gallery, elevated with modern live animation. This is a daily-driver tool; the chrome must move.

Two new `NSView` subclasses — `ChromeHostView` and `InteriorView` — replace the old content-view mask. `ChromeHostView` is the single alpha-aware renderer that owns the window silhouette via a static base image's alpha channel, with zero-to-many animated sublayers composited on top. `InteriorView` is pinned to the skin-declared `interiorRect` and is the sole parent of app content (tab bar, sidebar, terminal, input box). App content is inside the polygon **by construction, not by masking**.

Everything the Amplify v1 pipeline ships today — `.wamp` loader, sprite engine, font pipeline, bundle cache, skin picker, hot reload debouncer, `SkinWarningBanner`, `ShapedBorderlessWindow` subclass, `HitRegionSampler` polygon point-in-polygon, `DragRegionTracker`, `isReleasedWhenClosed = false` crash fix, `windowShape.polygons` descriptor — is preserved. The work described here replaces the window-shape rendering piece only, adds an animated-layer compositor, and extends the manifest with a v4 `chrome` descriptor while leaving v2 and v3 skins rendering unchanged. The old CA-mask path is deleted only in the final PR, after every in-tree shaped skin has migrated to v4 with animations verified live.

Target: macOS 15+ on Apple Silicon. Animated rendering runs on main-thread vsync-paced `CADisplayLink` clocks; Metal shader presets use `CAMetalLayer`; particle emitters use `CAEmitterLayer`. No new third-party Swift packages.

## Glossary

- **Animated_Chrome_Layer**: A single declarative entry in `chrome.animations` describing one of four live rendering primitives (`particle`, `ledArray`, `spriteAnim`, `shader`). Installed by `ChromeHostView` as a sublayer, z-ordered per the manifest, clipped to the base image's alpha.
- **Animation_Frame_Budget**: The per-frame wall-clock ceiling for all Animated_Chrome_Layers combined: 8 ms per 16.6 ms frame at 60 fps, measured via `os_signpost` around the compositor commit phase.
- **Baked_Mode**: One of two Chrome_Authoring_Modes. The skin author ships `chrome@2x.png` (and optionally `chrome-opaque@2x.png` for Reduce Transparency) and the engine installs the image directly as `baseLayer.contents`.
- **Base_Layer**: The `CALayer` inside `ChromeHostView` whose `contents` is the static RGBA chrome image. Its alpha channel IS the window silhouette.
- **Chrome_Animation_Layer_Descriptor**: The `ChromeAnimationLayer` struct in `Sources/Holoscape/Models/AmplifyDescriptors.swift` — carries id, kind, rect, z, phaseOffset, speedMultiplier, and kind-discriminated params.
- **Chrome_Authoring_Modes**: The two per-skin choices for producing the static base image: Baked_Mode and Composed_Mode.
- **Chrome_Descriptor**: The `ChromeDescriptor` struct added to `SkinDefinition` as the `chrome` field. Declares mode, image paths, interiorRect, optional interior path, and the array of Animated_Chrome_Layers.
- **Chrome_Host_View**: The `@MainActor` `NSView` subclass (`Sources/Holoscape/Views/ChromeHostView.swift`, new) that owns the Base_Layer and every Animated_Chrome_Layer. Single alpha-aware renderer for the window; no interactive subviews inside it.
- **Chrome_Mode_Branch**: The conditional path in `MainWindowController.applySkin` that installs Chrome_Host_View + Interior_View when `chrome` is present in the manifest, skipping the old `CALayer.mask` path.
- **Composed_Mode**: One of two Chrome_Authoring_Modes. The skin declares v3 surface descriptors as today and the engine composites a static base image at Chrome_Load_Time_Bake, caches it by SHA, and installs it.
- **Chrome_Load_Time_Bake**: The load-time pipeline that walks v3 surfaces + sprites + ninepatches for a Composed_Mode skin, draws them into a `CGContext` at `(width*2, height*2)` pixels, SHAs the inputs, and caches the resulting RGBA PNG at `~/Library/Caches/holoscape-skins/<sha>.png`.
- **Chrome_Manifest_Validator**: The load-time checker that (a) cross-checks `windowShape.polygons` bounding box vs Base_Layer alpha bounds with ±2 logical-pixel tolerance, (b) validates every Chrome_Animation_Layer_Descriptor for id uniqueness, rect bounds, kind-specific param well-formedness, and referenced-asset existence.
- **Chrome_SHA_Cache**: The on-disk cache at `~/Library/Caches/holoscape-skins/<sha>.png` that stores deterministic bake outputs. Governed by the existing 50 MB `.wamp` cache cap.
- **Chrome_Silhouette**: The set of pixels in Base_Layer where alpha > 0. No Animated_Chrome_Layer may render a pixel outside the silhouette.
- **Debug_Overlay**: The opt-in diagnostic render path enabled by `HOLOSCAPE_PNG_CHROME_DEBUG=1`. Overlays false-colored alpha, interiorRect outline, windowShape polygons, animated-layer bounds + id labels, and a live phase clock.
- **Density_Mode**: The existing runtime mode (`DensityModeManager`) with three values: `.off` removes Animated_Chrome_Layers entirely, `.minimal` pauses them on their starting frame, `.full` animates normally.
- **Drag_Background**: The AppKit drag affordance enabled by `NSWindow.isMovableByWindowBackground = true`. The Base_Layer's opaque pixels are the background; AppKit's drag-from-bare-background requirement is satisfied wherever the Base_Layer is opaque and no interactive subview covers.
- **Interior_Rect**: The `SkinRect` inside `ChromeDescriptor` declaring where Interior_View is pinned, in chrome-image coordinate space (top-left origin).
- **Interior_View**: The `@MainActor` `NSView` subclass (`Sources/Holoscape/Views/InteriorView.swift`, new) pinned to Interior_Rect. Sole parent of all app content. For concave interiors, `InteriorView.layer.mask` is set to a `CAShapeLayer` of `interiorPath`.
- **LED_Array_Layer**: An Animated_Chrome_Layer rendered as a `CALayer` subtree of cells, each cell colored from `LedArrayParams.palette`, animated via one of five Pattern values (`steady`, `blink`, `phased`, `random`, `marquee`) on a shared `CADisplayLink`-paced clock.
- **Particle_Emitter_Layer**: An Animated_Chrome_Layer backed by `CAEmitterLayer` with declared birth rate, lifetime, velocity, color, scale, and optional image.
- **Polygon_Alpha_Agreement**: The ±2 logical-pixel tolerance within which the bounding box of `windowShape.polygons` must match the non-zero-alpha bounding box of Base_Layer.
- **Reduce_Motion_Freeze**: The behavior required when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == true`: all Animated_Chrome_Layers freeze on their starting frame; they are not hidden, only paused.
- **Reduce_Transparency_Fallback**: The behavior required when `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true`: use `chrome.imageOpaque` if declared, otherwise multiply Base_Layer alpha to 1.0 on non-zero-alpha pixels.
- **Shader_Preset_Layer**: An Animated_Chrome_Layer backed by `CAMetalLayer` running one of three MVP-shipped built-in Metal shaders: `glow`, `scanlines`, `noise`. Shaders compile at app build time from `.metal` sources in the app bundle.
- **Shaped_Borderless_Window**: The existing `NSWindow` subclass (`Sources/Holoscape/Views/ShapedContentView.swift`) that overrides `canBecomeKey` and `canBecomeMain` to return true, so a `.borderless` window still accepts keyboard focus. Carries forward verbatim.
- **Shared_Animation_Clock**: A per-skin `CADisplayLink` instance feeding the vsync-paced `CACurrentMediaTime()` phase to every LED_Array_Layer and Sprite_Animation_Layer. Re-used across layers so animations stay in phase.
- **Single_Container_Mask**: The single `CAShapeLayer` (or alpha-derived mask) installed on the parent of all Animated_Chrome_Layers. Derived from Base_Layer alpha. Clips every animated layer to Chrome_Silhouette in one operation. Chosen over per-layer masking because it's cheaper, simpler, and equivalent for the convex + compound-polygon case (PRD decision, FR-21).
- **Skin_Definition_V4**: The v4 `SkinDefinition` manifest adding the optional `chrome: ChromeDescriptor?` field. v2/v3 manifests without `chrome` continue to work under the pre-existing path. Presence of `chrome` opts into the Chrome_Mode_Branch.
- **Skin_Warning_Banner**: The existing `SkinWarningBanner` NSView that fades in for 5 seconds to report manifest errors at skin-load time. Carries forward verbatim; receives new reason strings from Chrome_Manifest_Validator.
- **Sprite_Animation_Layer**: An Animated_Chrome_Layer that cycles `layer.contentsRect` UV offsets across a sprite sheet at a declared fps with a declared loop mode (`loop`, `pingPong`, `once`).
- **Window_Shape**: The `windowShape.polygons` descriptor from v3. Kept verbatim. Drives hit testing (`HitRegionSampler`), drag regions (`DragRegionTracker`), and cross-check validation against Base_Layer alpha.

## Requirements

### Requirement 1: Chrome Descriptor and Skin Definition v4

**User Story:** As Erik, I want to declare a static chrome base image plus an ordered list of animated layers in the skin manifest, so that skin authors can paint the window silhouette and ship live chrome without writing code.

#### Acceptance Criteria

1. THE Holoscape SHALL decode a `SkinDefinition` with an optional `chrome: ChromeDescriptor?` field where `ChromeDescriptor` carries `mode`, `image`, `imageOpaque`, `width`, `height`, `interiorRect`, optional `interiorPath`, and optional `animations`.
2. WHEN `ChromeDescriptor.mode == .baked`, THE Holoscape SHALL require `image` to be a non-nil bundle-relative path.
3. WHEN `ChromeDescriptor.mode == .composed`, THE Holoscape SHALL permit `image` to be nil and produce the Base_Layer via Chrome_Load_Time_Bake from the skin's v3 surfaces.
4. THE Holoscape SHALL decode each Chrome_Animation_Layer_Descriptor with a unique `id`, a `kind` in `{particle, ledArray, spriteAnim, shader}`, a `rect`, a `z` integer, optional `phaseOffset`, optional `speedMultiplier`, and kind-discriminated `params`.
5. THE Holoscape SHALL decode `ParticleParams`, `LedArrayParams`, `SpriteAnimParams`, and `ShaderParams` Codable round-trips without loss of information.
6. WHEN a v2 or v3 manifest omits `chrome`, THE Holoscape SHALL decode the manifest unchanged and route rendering through the pre-existing non-chrome path.
7. THE Holoscape SHALL treat coordinate origins in `ChromeDescriptor.interiorRect`, `SkinRect`, and every animation `rect` as top-left to match image-editor conventions, converting internally to AppKit's bottom-left coordinate space.

### Requirement 2: Chrome Host View and Interior View

**User Story:** As Erik, I want one alpha-aware compositor to own every chrome pixel and one view to own every app-content pixel, so that adding a new subview can never break the window shape.

#### Acceptance Criteria

1. THE Holoscape SHALL install `Chrome_Host_View` as the single child of `ShapedContentView` whenever a Skin_Definition_V4 with `chrome` loads, filling the content view's bounds.
2. THE Holoscape SHALL set `Chrome_Host_View.layer.contents` to the static RGBA Base_Layer image derived from the active Chrome_Authoring_Modes path.
3. THE Holoscape SHALL install `Interior_View` as a sibling of `Chrome_Host_View` pinned to `chrome.interiorRect` in chrome-image coordinates.
4. THE Holoscape SHALL parent every piece of app content (TabBarView, NSSplitView, sidebar, SplitPaneManager, HoloscapeTerminalView, InputBoxView, SessionLauncherView) to Interior_View, not to `ShapedContentView` and not to `Chrome_Host_View`.
5. THE Holoscape SHALL NOT install any interactive subview (a subview that responds to mouse or keyboard events) inside Chrome_Host_View.
6. WHEN `chrome.interiorPath` is non-nil, THE Holoscape SHALL install a `CAShapeLayer` mask built from `interiorPath` on `Interior_View.layer`.
7. WHEN `chrome.interiorPath` is nil, THE Holoscape SHALL leave `Interior_View.layer.mask` as nil and rely on the view's frame as the sole interior clip.
8. THE Holoscape SHALL keep `Interior_View.frame` equal to `chrome.interiorRect` (converted to AppKit coordinates) after every layout pass.

### Requirement 3: Alpha-Based Window Transparency

**User Story:** As Erik, I want cut-corner pixels of the window to reveal the desktop behind, so that Holoscape looks shaped instead of dark-rectangled.

#### Acceptance Criteria

1. THE Holoscape SHALL configure the `NSWindow` as `.borderless`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` whenever Skin_Definition_V4 chrome is active.
2. WHEN a Base_Layer pixel has alpha == 0, THE Holoscape SHALL render the corresponding window pixel as fully transparent.
3. WHEN a Base_Layer pixel has 0 < alpha < 1, THE Holoscape SHALL render the corresponding window pixel with the matching partial alpha.
4. THE Holoscape SHALL ensure that Base_Layer alpha IS the sole source of truth for window silhouette shape — no descendant layer's `backgroundColor` contributes to window opacity outside Chrome_Silhouette.
5. WHEN the window is dragged over a visibly-bright backdrop, THE Holoscape SHALL render the backdrop through every pixel where Base_Layer alpha == 0.
6. THE Holoscape SHALL keep `contentMinSize == contentMaxSize == (chrome.width, chrome.height)` and strip `.resizable` from the `styleMask` whenever a Skin_Definition_V4 chrome is active.

### Requirement 4: Hit Testing, Drag Regions, and Click-Through

**User Story:** As Erik, I want clicks outside the chrome silhouette to pass through to whatever is behind Holoscape, and clicks inside to route normally, so that a shaped window behaves like a shaped window on the desktop.

#### Acceptance Criteria

1. THE Holoscape SHALL call `HitRegionSampler.contains(point)` against `windowShape.polygons` inside `ShapedContentView.hitTest(_:)` for every incoming hit test.
2. WHEN a hit test point falls outside every `windowShape.polygons` entry, THE Holoscape SHALL return nil from `hitTest(_:)` to produce native click-through.
3. WHEN a hit test point falls inside any `windowShape.polygons` entry, THE Holoscape SHALL delegate to `super.hitTest(_:)` to route the event to descendant views.
4. THE Holoscape SHALL continue to honor `dragRegions` descriptors via `DragRegionTracker` and `NSTrackingArea` installation.
5. THE Holoscape SHALL set `NSWindow.isMovableByWindowBackground = true` when Skin_Definition_V4 chrome is active so Drag_Background works on any bare Base_Layer pixel.
6. THE Holoscape SHALL NOT install `WindowDragOverlay` when Skin_Definition_V4 chrome is active; Drag_Background and the optional `dragRegions` descriptors cover the drag surface.

### Requirement 5: Chrome Load-Time Bake (Composed Mode)

**User Story:** As Erik, I want existing v3 skins to become v4 with zero author repainting, so that HoloscapeSynthwave and AmplifyDemo migrate by dropping in `chrome.interiorRect` and nothing else.

#### Acceptance Criteria

1. WHEN `ChromeDescriptor.mode == .composed`, THE Holoscape SHALL walk the skin's v3 surfaces + sprites + ninepatches and draw them into a `CGContext` at `(chrome.width * 2, chrome.height * 2)` pixels.
2. THE Holoscape SHALL compute a SHA-256 hash over the concatenated manifest JSON bytes and every referenced asset's bytes, and use that hash as the Chrome_SHA_Cache key.
3. THE Holoscape SHALL write the composed RGBA PNG to `~/Library/Caches/holoscape-skins/<sha>.png` on cache miss and read it back as `CGImage` bytes.
4. WHEN the cache contains `<sha>.png`, THE Holoscape SHALL skip the compositing work and decode the cached PNG directly.
5. WHEN any input to the Chrome_SHA_Cache hash changes (manifest field, surface descriptor, sprite sheet, ninepatch), THE Holoscape SHALL recompute the hash, miss the cache, and re-bake.
6. THE Holoscape SHALL enforce the existing 50 MB cache cap across Chrome_SHA_Cache entries and `.wamp` unzip entries combined, purging least-recently-used entries first.
7. THE Holoscape SHALL complete the first cold bake in ≤ 500 ms for a 1000×700 logical-size skin on Apple Silicon.
8. THE Holoscape SHALL complete a cache hit in ≤ 30 ms for the same skin size.

### Requirement 6: Particle Emitter Layer

**User Story:** As Erik, I want a skin author to declare drifting sparks inside a porthole or ambient glow dust behind glass without writing Core Animation code, so that the chrome feels alive.

#### Acceptance Criteria

1. WHEN a Chrome_Animation_Layer_Descriptor has `kind == .particle`, THE Holoscape SHALL install a `CAEmitterLayer` inside Chrome_Host_View z-ordered per the layer's `z` and bounded to `layer.rect`.
2. THE Holoscape SHALL apply every `ParticleParams` field (birthRate, lifetime, lifetimeRange, velocity, velocityRange, emissionAngle, emissionRange, color, colorRange, scale, scaleRange, image, blendMode) to the installed `CAEmitterLayer`.
3. WHEN `ParticleParams.image` is nil, THE Holoscape SHALL synthesize a procedurally-generated soft dot as the particle's rendered image.
4. WHEN `ParticleParams.blendMode` is `.additive` or `.screen`, THE Holoscape SHALL set the corresponding `compositingFilter` on the emitter cell.
5. WHILE a Particle_Emitter_Layer is active, THE Holoscape SHALL clip every emitted particle to Chrome_Silhouette via Single_Container_Mask.

### Requirement 7: LED Array Layer

**User Story:** As Erik, I want a skin author to declare status LED ladders, equalizer strips, and marquee patterns with a flat list of cell positions and a pattern enum, so that living instrument panels are a one-descriptor job.

#### Acceptance Criteria

1. WHEN a Chrome_Animation_Layer_Descriptor has `kind == .ledArray`, THE Holoscape SHALL install a `CALayer` subtree inside Chrome_Host_View z-ordered per the layer's `z` and bounded to `layer.rect`.
2. THE Holoscape SHALL render one sub-`CALayer` per `LedArrayParams.cells` entry, sized `cellSize × cellSize` and positioned at the cell's `(x, y)` in top-left coordinates inside the layer's rect.
3. THE Holoscape SHALL color each cell using the palette entry at the cell's current state index.
4. WHEN `pattern == .steady`, THE Holoscape SHALL hold every cell at its `defaultState` palette index indefinitely.
5. WHEN `pattern == .blink(hz, duty)`, THE Holoscape SHALL alternate every cell between `defaultState` and `(defaultState + 1) % palette.count` at `hz` Hz with `duty` fraction on-time per cycle.
6. WHEN `pattern == .phased(hz)`, THE Holoscape SHALL light cells in sequence at `hz` cells-per-second, returning to the first cell after the last lights.
7. WHEN `pattern == .random(hz, density)`, THE Holoscape SHALL re-randomize cell states at `hz` Hz with the target fraction of `density` cells in the non-default state.
8. WHEN `pattern == .marquee(cellsPerSecond, windowSize)`, THE Holoscape SHALL light a contiguous window of `windowSize` cells that scrolls at `cellsPerSecond` cells-per-second, wrapping at the end of the cell list.
9. THE Holoscape SHALL build palette swatches and cell geometry exactly once at skin load, with zero per-frame allocation.
10. THE Holoscape SHALL drive LED cell state from a single Shared_Animation_Clock and apply the layer's `phaseOffset` and `speedMultiplier` deterministically.

### Requirement 8: Sprite Animation Layer

**User Story:** As Erik, I want a skin author to drop in a rotating dial, spinning record, or scrolling LCD marquee by pointing at a sprite sheet and declaring rows/cols/fps/loop, so that classic animated chrome elements are first-class.

#### Acceptance Criteria

1. WHEN a Chrome_Animation_Layer_Descriptor has `kind == .spriteAnim`, THE Holoscape SHALL install a `CALayer` whose `contents` is the declared sprite sheet image, bounded to `layer.rect`, z-ordered per the layer's `z`.
2. THE Holoscape SHALL advance `layer.contentsRect` UV offsets across the `gridRows × gridCols` sheet at `fps` frames per second.
3. THE Holoscape SHALL advance at most `frameCount` frames per loop iteration, regardless of grid capacity.
4. WHEN `loop == .loop`, THE Holoscape SHALL wrap from the last frame to the first frame at the end of each iteration.
5. WHEN `loop == .pingPong`, THE Holoscape SHALL reverse direction at each end of the sequence.
6. WHEN `loop == .once`, THE Holoscape SHALL hold on the final frame after the first full iteration.
7. THE Holoscape SHALL drive sprite frame advancement from Shared_Animation_Clock with the layer's `phaseOffset` and `speedMultiplier` applied.

### Requirement 9: Shader Preset Layer

**User Story:** As Erik, I want a skin author to pick a named shader preset and supply a color, intensity, and frequency, so that glass glows, CRT scanlines, and film grain are one-line manifest entries.

#### Acceptance Criteria

1. WHEN a Chrome_Animation_Layer_Descriptor has `kind == .shader`, THE Holoscape SHALL install a `CAMetalLayer` inside Chrome_Host_View z-ordered per the layer's `z` and bounded to `layer.rect`.
2. THE Holoscape SHALL ship `glow`, `scanlines`, and `noise` as built-in Metal shaders compiled from `.metal` source files in the app bundle at app build time.
3. THE Holoscape SHALL bind `ShaderParams.color`, `ShaderParams.intensity`, and `ShaderParams.hz` to the active shader's uniform buffer per the shader's documented parameter schema.
4. WHEN `ShaderParams.preset` is not one of `glow`, `scanlines`, `noise`, THE Holoscape SHALL skip installing the layer, log a warning naming the offending layer `id`, and surface the Skin_Warning_Banner with the failure reason.
5. WHILE a Shader_Preset_Layer is active, THE Holoscape SHALL set `CAMetalLayer.isOpaque = false` and `framebufferOnly = false` so alpha compositing into Chrome_Host_View is preserved.

### Requirement 10: Animated Layer Clipping and Z-Ordering

**User Story:** As Erik, I want animated particles and shaders to never paint through transparent regions of the chrome, so that the silhouette rule is absolute.

#### Acceptance Criteria

1. THE Holoscape SHALL install a Single_Container_Mask on the parent layer of every Animated_Chrome_Layer, derived from the non-zero-alpha bounds of Base_Layer.
2. THE Holoscape SHALL NOT render any pixel of any Animated_Chrome_Layer where Base_Layer alpha == 0.
3. THE Holoscape SHALL order Animated_Chrome_Layers from lowest `z` (closest to Base_Layer) to highest `z` (closest to Interior_View).
4. WHEN two Animated_Chrome_Layers share the same `z`, THE Holoscape SHALL order them by their position in `chrome.animations` (earlier in the array renders first).
5. THE Holoscape SHALL ensure Base_Layer is always rendered below every Animated_Chrome_Layer (Base_Layer has implicit z = 0 and every animated layer with z ≤ 0 is invalid and rejected by Chrome_Manifest_Validator).

### Requirement 11: Animation Frame Budget and Performance

**User Story:** As Erik, I want live chrome to run at 60 fps on my M1 laptop without stealing frame budget from the terminal, so that "cooler than Winamp" doesn't cost typing latency.

#### Acceptance Criteria

1. THE Holoscape SHALL sustain 60 fps in Chrome_Host_View for any skin that respects the declared per-frame ceilings during normal Holoscape use (typing, scrolling, pane switches) on Apple Silicon M1 or later.
2. THE Holoscape SHALL keep aggregate Animated_Chrome_Layer commit time under 8 ms per frame measured via `os_signpost` regions around the compositor commit phase.
3. THE Holoscape SHALL instrument every PR touching the compositor with `os_signpost` traces so Animation_Frame_Budget is continuously verifiable.
4. THE Holoscape SHALL reject particle emitters whose declared texture allocation would exceed 64 MB of GPU memory on an M1 baseline, surfacing Skin_Warning_Banner and disabling the layer.
5. WHEN frame time exceeds 16.6 ms on hardware older than M1, THE Holoscape SHALL drop frames rather than rendering incorrectly or freezing the main thread.

### Requirement 12: Chrome Manifest Validator

**User Story:** As Erik, I want malformed chrome manifests to produce specific, actionable warnings at skin load, so that authoring mistakes never corrupt state or crash the app.

#### Acceptance Criteria

1. THE Holoscape SHALL compute the non-zero-alpha bounding box of Base_Layer and compare it to the bounding box of `windowShape.polygons` at skin load time.
2. WHEN Polygon_Alpha_Agreement fails (bounding boxes disagree by more than 2 logical pixels in any dimension), THE Holoscape SHALL display Skin_Warning_Banner with a reason string naming the mismatched dimension and the observed delta in pixels.
3. THE Holoscape SHALL validate that every Chrome_Animation_Layer_Descriptor `id` is unique within `chrome.animations`.
4. THE Holoscape SHALL validate that every Chrome_Animation_Layer_Descriptor `rect` is inside `(0, 0, chrome.width, chrome.height)`.
5. THE Holoscape SHALL validate kind-specific params: `gridRows * gridCols >= frameCount` for sprite animations; `birthRate > 0` for particles; `palette.count > 0` and every cell's `defaultState` inside `[0, palette.count)` for LED arrays; `preset` in `{glow, scanlines, noise}` for shader presets.
6. THE Holoscape SHALL validate that every referenced sprite sheet path and every referenced particle image path exists in the skin bundle.
7. WHEN any animated-layer validation fails, THE Holoscape SHALL display Skin_Warning_Banner with a reason string naming the offending layer `id` and the specific validation that failed.
8. WHEN `chrome.image` is missing, not an RGBA PNG, dimension-mismatched with declared `width`/`height`, or `interiorRect` falls outside image bounds, THE Holoscape SHALL display Skin_Warning_Banner and fall back to rectangular rendering using the skin's declared v3 surface fills.
9. THE Holoscape SHALL warn (not reject) when `chrome.width < 200` or `chrome.height < 100` as a minimum-size sanity check.

### Requirement 13: Hot Reload and Skin Switching

**User Story:** As Erik, I want chrome image edits, composed-surface edits, and animation edits to live-reload within the existing debounce window, so that authoring feels immediate.

#### Acceptance Criteria

1. WHEN the chrome image file, any v3 surface referenced by a Composed_Mode skin, or any entry in `chrome.animations` changes on disk, THE Holoscape SHALL fire the existing FSEventStream hot-reload path.
2. THE Holoscape SHALL coalesce hot-reload events with the existing 200 ms debounce window.
3. WHEN a Composed_Mode skin reloads, THE Holoscape SHALL re-run Chrome_Load_Time_Bake, miss the cache if inputs changed, and swap Base_Layer `contents` atomically.
4. WHEN a Baked_Mode skin reloads, THE Holoscape SHALL re-decode `chrome.image` and swap Base_Layer `contents` atomically.
5. WHEN `chrome.animations` changes, THE Holoscape SHALL diff the new descriptor list against the running set by `id`, destroy removed layers, install new layers, and swap params in place on existing layers.
6. WHEN the active skin swap is triggered and `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == true`, THE Holoscape SHALL swap Base_Layer and animated layers instantly without any crossfade or animation.

### Requirement 14: Debug Overlay

**User Story:** As Erik, I want a debug overlay that shows alpha, interior rect, polygons, animated-layer bounds, and phase clock simultaneously, so that skin authors can see exactly what the compositor is doing while iterating.

#### Acceptance Criteria

1. WHEN the `HOLOSCAPE_PNG_CHROME_DEBUG` environment variable equals `"1"`, THE Holoscape SHALL install Debug_Overlay on top of every Animated_Chrome_Layer inside Chrome_Host_View.
2. THE Holoscape SHALL render a semitransparent false-color visualization of Base_Layer alpha inside Debug_Overlay.
3. THE Holoscape SHALL render a red outline of `chrome.interiorRect` inside Debug_Overlay.
4. THE Holoscape SHALL render a green overlay of every `windowShape.polygons` entry inside Debug_Overlay.
5. THE Holoscape SHALL render a yellow outline and `id` text label for every Animated_Chrome_Layer's `rect` inside Debug_Overlay.
6. THE Holoscape SHALL render a live clock text readout showing `CACurrentMediaTime()` phase seconds inside Debug_Overlay, updated every frame.
7. WHEN `HOLOSCAPE_PNG_CHROME_DEBUG` is unset or not `"1"`, THE Holoscape SHALL NOT install Debug_Overlay.

### Requirement 15: Accessibility and Density Modes

**User Story:** As Erik, I want Reduce Motion, Reduce Transparency, and density modes to govern animated chrome exactly as they govern every other surface, so that accessibility preferences are never bypassed.

#### Acceptance Criteria

1. WHEN `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true` and `chrome.imageOpaque` is declared, THE Holoscape SHALL use `chrome.imageOpaque` as Base_Layer `contents`.
2. WHEN `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true` and `chrome.imageOpaque` is nil, THE Holoscape SHALL render Base_Layer with alpha multiplied to 1.0 on every pixel where source alpha > 0.
3. WHEN `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == true`, THE Holoscape SHALL freeze every Animated_Chrome_Layer on its starting frame without hiding the layer.
4. WHEN Density_Mode equals `.off`, THE Holoscape SHALL remove every Animated_Chrome_Layer from Chrome_Host_View's sublayer tree, producing zero CPU and zero GPU cost.
5. WHEN Density_Mode equals `.minimal`, THE Holoscape SHALL pause every Animated_Chrome_Layer on its current frame while keeping the layer in the tree and visible.
6. WHEN Density_Mode equals `.full`, THE Holoscape SHALL animate every Animated_Chrome_Layer normally.
7. WHEN Density_Mode transitions from `.full` to `.minimal`, THE Holoscape SHALL preserve the current frame of every active Animated_Chrome_Layer.
8. WHEN Density_Mode transitions from `.minimal` to `.off`, THE Holoscape SHALL remove every Animated_Chrome_Layer cleanly without leaving orphaned layers.
9. WHEN Density_Mode transitions from `.off` to `.full`, THE Holoscape SHALL restart every Animated_Chrome_Layer from its declared `phaseOffset`.
10. THE Holoscape SHALL mark every Animated_Chrome_Layer as `.accessibilityElementIsHidden = true` so VoiceOver skips them.

### Requirement 16: Backward Compatibility and Old-Path Deletion

**User Story:** As Erik, I want every existing skin format and every in-tree shaped skin to keep rendering through the transition, so that migration is never a hard cutover.

#### Acceptance Criteria

1. THE Holoscape SHALL continue to load v1, v2, and v3 skins (directory-layout and `.wamp`) without modification.
2. WHEN a skin declares `windowShape` but omits `chrome`, THE Holoscape SHALL route rendering through the pre-existing `CALayer.mask` path until the final old-path-deletion PR lands.
3. WHEN a skin declares `chrome`, THE Holoscape SHALL route rendering through Chrome_Mode_Branch and skip the old `CALayer.mask` path entirely.
4. THE Holoscape SHALL pass every existing `BackwardCompatIntegrationTests` scenario.
5. THE Holoscape SHALL add six new `BackwardCompatIntegrationTests` scenarios covering: v4 composed directory without animations, v4 composed `.wamp` without animations, v4 baked directory without animations, v4 baked `.wamp` without animations, v4 composed with every MVP animation kind, v4 baked with every MVP animation kind.
6. THE Holoscape SHALL NOT delete `ShapedWindowController.buildMaskLayer`, `WindowDragOverlay`, polygon scaling, `windowDidResizeForShape`, or `writeShapeDiagnostic` until (a) `HoloscapeClassic-live` has been authored and rendered live on v4 (b) the pre-v4 `HoloscapeClassic` skin directory has been deleted from the tree as superseded, (c) `HoloscapeSynthwave` and `AmplifyDemo` have been migrated to v4 `chrome` descriptors, and (d) every `BackwardCompatIntegrationTests` scenario passes with animations verified live.
7. THE Holoscape SHALL preserve `HitRegionSampler`, `DragRegionTracker`, `ShapedBorderlessWindow`, `isReleasedWhenClosed = false`, and `SkinWarningBanner` verbatim across the transition.
