# Requirements Document

## Introduction

PNG Chrome replaces Amplify v1's `CALayer.mask` polygon-clipping approach with a single alpha-aware compositing host architecture for non-rectangular, visually-distinctive, live-animated Holoscape windows. Instead of masking a borderless NSWindow's content view to clip a polygon shape (which failed due to descendant layers' `backgroundColor` painting through the mask), one compositing host (`ChromeHostView`) owns every visible chrome pixel via an RGBA PNG whose alpha channel IS the window shape, while a separate `InteriorView` pinned to the skin's declared `interiorRect` owns all app content. Animated chrome layers (particle emitters, LED arrays, sprite animations, shader presets) composite on top of the static base within the chrome silhouette, delivering the Winamp-class instrument-panel aesthetic with live animation as a first-class primitive.

This spec supersedes the shape + drag-region sections of the Amplify skinning spec. Chrome skinning surfaces, sprites, fonts, `.wamp` bundles, and the skin picker carry forward unchanged from Amplify v1.

## Glossary

- **Chrome_Host_View**: A layer-backed `NSView` whose sublayer tree composites a static base layer (RGBA PNG) with zero or more animated chrome layers. Every pixel rendered by this view respects the base layer's alpha. Contains no interactive subviews.
- **Interior_View**: An `NSView` pinned to the skin's declared `interiorRect` inside the chrome. The ONLY parent of app content (terminal, sidebar, tab bar, input box, session launcher).
- **Chrome_Descriptor**: A Codable struct declaring the chrome mode (`baked` or `composed`), static base image path, dimensions, interior rect, optional interior path for concave interiors, and optional animated layer array.
- **Skin_Rect**: A Codable struct representing a rectangle in chrome-image coordinate space (`x`, `y`, `width`, `height`).
- **Chrome_Animation_Layer**: A Codable struct declaring one animated layer's kind, bounds, z-order, phase offset, speed multiplier, and kind-specific parameters.
- **Particle_Params**: Declarative parameters for a `CAEmitterLayer`-backed particle emitter (birth rate, lifetime, velocity, emission angle, color, scale, blend mode, optional sprite image).
- **Led_Array_Params**: Declarative parameters for an LED array layer (cell size, cell positions, palette, blink/phase/random/marquee pattern).
- **Sprite_Anim_Params**: Declarative parameters for a sprite-animation layer (sheet path, grid dimensions, frame count, fps, loop mode).
- **Shader_Params**: Declarative parameters for a named built-in Metal shader preset (`glow`, `scanlines`, `noise`) with color, intensity, and frequency controls.
- **Skin_Engine**: The `SkinEngine` class responsible for discovering, loading, validating, and caching skins. Owns the FSEventStream file watcher and font registration lifecycle.
- **Skin_Definition**: The `SkinDefinition` Codable model representing a skin manifest (`skin.json`). Amplify v3 fields carry forward; PNG Chrome adds v4 `chrome` field.
- **Skin_Context**: The `SkinContext` class that chrome views query at runtime for resolved surface appearance.
- **Shaped_Content_View**: The existing `ShapedContentView` NSView subclass that overrides `hitTest(_:)` for click-through outside the polygon region.
- **Hit_Region_Sampler**: The existing polygon point-in-polygon tester used for click-through hit testing.
- **Density_Mode_Manager**: The `DensityModeManager` class gating skin features at three levels: Full (all features), Minimal (static frames only), Off (skin engine bypassed).
- **Chrome_View**: Any AppKit view in the Holoscape chrome layer that resolves its appearance through Skin_Context.
- **Wamp_Bundle**: A ZIP-based distributable skin package with `.wamp` extension.
- **Load_Time_Bake**: The process of compositing v3 surface descriptors into a single RGBA `CGImage` at skin load time, cached by SHA of the inputs.
- **Debug_Overlay**: A diagnostic rendering mode activated by `HOLOSCAPE_PNG_CHROME_DEBUG=1` that visualizes alpha values, interior rect, polygon outlines, animated layer bounds, and phase clock.

## Requirements

### Requirement 1: Chrome Image as Window Shape via Alpha Compositing

**User Story:** As a skin author, I want to ship an RGBA PNG whose alpha channel defines the window shape, so that Holoscape renders non-rectangular windows with actual desktop transparency without the CALayer.mask bugs.

#### Acceptance Criteria

1. WHEN a skin manifest contains a `chrome` field with `mode` equal to `"baked"` and a valid `image` path, THE Skin_Engine SHALL install Chrome_Host_View as the full-bounds child of Shaped_Content_View with the chrome image as `baseLayer.contents`.
2. WHEN a skin manifest contains a `chrome` field with `mode` equal to `"composed"`, THE Skin_Engine SHALL composite the v3 surface descriptors into a single RGBA `CGImage` via the Load_Time_Bake pipeline and install the result as `baseLayer.contents` on Chrome_Host_View.
3. WHEN Chrome_Host_View is installed, THE MainWindowController SHALL configure the NSWindow as borderless (`styleMask: [.borderless, .fullSizeContentView]`), `isOpaque = false`, `backgroundColor = .clear`, and `hasShadow = false`.
4. WHEN the chrome image contains pixels with alpha less than 1.0, THE window SHALL render those pixels with commensurate transparency, revealing the desktop behind.
5. WHEN the chrome image contains pixels with alpha equal to 0, THE window SHALL render those pixels as fully transparent, revealing the desktop behind.
6. WHEN a skin manifest contains no `chrome` field, THE MainWindowController SHALL retain the existing window configuration (titled, resizable, rectangular) with no behavior change.

### Requirement 2: Fixed-Size Window Under Chrome Mode

**User Story:** As a skin author, I want the window to be fixed to the chrome image's declared dimensions, so that the chrome artwork renders at its intended size without distortion.

#### Acceptance Criteria

1. WHEN a `chrome` field is present, THE MainWindowController SHALL set `contentMinSize` and `contentMaxSize` both equal to `(chrome.width, chrome.height)` and strip the `.resizable` style mask flag.
2. WHEN a `chrome` field is absent, THE MainWindowController SHALL retain the existing resizable window behavior.

### Requirement 3: Interior View Owns All App Content

**User Story:** As a developer, I want all app content (terminal, sidebar, tab bar, input box, session launcher) parented to a single Interior_View pinned to the skin's declared interior rect, so that app content is geometrically inside the chrome's opaque region by construction.

#### Acceptance Criteria

1. WHEN a `chrome` field is present, THE MainWindowController SHALL create an Interior_View pinned to `chrome.interiorRect` in chrome-image coordinates and reparent all existing app content subviews (terminal, sidebar, tab bar, input box, session launcher, chrome bands) under Interior_View.
2. THE Interior_View SHALL use its own bounds as the layout coordinate space, treating `(0, 0, interiorRect.width, interiorRect.height)` as the content area for child constraints.
3. WHEN `chrome.interiorPath` is declared (concave interior), THE Interior_View SHALL install a `CAShapeLayer` mask built from the interior path polygons to clip content to the concave region.
4. WHEN `chrome.interiorPath` is absent (convex interior), THE Interior_View SHALL NOT install any layer mask — the view's frame IS the clip.
5. WHEN a `chrome` field is absent, THE MainWindowController SHALL retain the existing layout where app content is parented directly to the content view.

### Requirement 4: Hit Testing via Existing Polygon

**User Story:** As a user, I want mouse clicks on transparent areas outside the skin's declared window shape to pass through to windows behind Holoscape, so that shaped windows behave like native non-rectangular surfaces.

#### Acceptance Criteria

1. WHEN a chrome-mode skin is active, THE Shaped_Content_View SHALL continue to use Hit_Region_Sampler with `windowShape.polygons` for click-through hit testing — returning nil for points outside the polygon region.
2. THE hit-test implementation SHALL NOT use alpha sampling of the chrome image — the polygon point-in-polygon tester is faster and already works.
3. WHEN no `windowShape` is declared in the skin manifest, THE Shaped_Content_View SHALL use the default rectangular hit-test behavior.

### Requirement 5: Manifest Validator Cross-Checks Polygon vs Chrome Image

**User Story:** As a skin author, I want the engine to warn me when my `windowShape.polygons` don't match my chrome image's non-transparent bounds, so that I catch misalignment between the visual shape and the hit-test shape.

#### Acceptance Criteria

1. WHEN a chrome-mode skin is loaded, THE Skin_Engine SHALL sample the chrome base image's alpha bounds and compare the bounding box to `windowShape.polygons`' bounding box.
2. WHEN the polygon bounding box and the chrome image's non-transparent bounding box differ by more than 2 logical pixels on any edge, THE Skin_Engine SHALL display a SkinWarningBanner naming the mismatched field.
3. WHEN the bounding boxes match within the 2-pixel tolerance, THE Skin_Engine SHALL proceed without warning.

### Requirement 6: Dragging via Window Background

**User Story:** As a user, I want to drag the window by clicking on the chrome's opaque pixels, so that shaped windows are movable without a system title bar.

#### Acceptance Criteria

1. WHEN a chrome-mode skin is active, THE MainWindowController SHALL set `window.isMovableByWindowBackground = true` so that AppKit's drag-from-background mechanism works on the chrome image's opaque pixels.
2. WHEN a chrome-mode skin is active, THE MainWindowController SHALL remove the `WindowDragOverlay` from Amplify v1 — the chrome image's opaque pixels serve as the drag surface directly.
3. WHEN explicit `dragRegions` are declared in the manifest, THE MainWindowController SHALL honor them as in Amplify v1 (polygon-based drag handles with optional modifier gating).

### Requirement 7: Chrome Authoring Mode — Baked

**User Story:** As a skin author, I want to ship a pre-rendered `chrome@2x.png` as the static base, so that I can paint the chrome in any image editor and have it render directly.

#### Acceptance Criteria

1. WHEN `chrome.mode` equals `"baked"` and `chrome.image` is a valid path to an RGBA PNG within the skin bundle, THE Skin_Engine SHALL decode the image and install it as `baseLayer.contents` on Chrome_Host_View.
2. THE Skin_Engine SHALL prefer `chrome@2x.png` for HiDPI displays, fall back to `chrome.png` at 1x if the @2x variant is absent, and optionally load `chrome@3x.png` on matching-backing-scale screens.
3. IF `chrome.mode` equals `"baked"` and `chrome.image` is missing or fails to decode, THEN THE Skin_Engine SHALL display a SkinWarningBanner and fall back to rectangular rendering with the declared v3 surface fills.

### Requirement 8: Chrome Authoring Mode — Composed

**User Story:** As a skin author with an existing v3 skin, I want the engine to composite my v3 surfaces into a chrome base image at load time, so that my skin migrates to the new architecture without repainting.

#### Acceptance Criteria

1. WHEN `chrome.mode` equals `"composed"`, THE Skin_Engine SHALL walk the v3 surface descriptors, draw each surface into a `CGContext` at `(chrome.width * 2, chrome.height * 2)` for @2x, and produce a single RGBA `CGImage`.
2. THE Skin_Engine SHALL compute a SHA hash of the composed inputs (surface descriptors, referenced image bytes, ninepatch sidecars) and cache the result at `~/Library/Caches/holoscape-skins/<sha>.png`.
3. WHEN the cache contains a valid entry for the current SHA, THE Skin_Engine SHALL load the cached image instead of re-compositing.
4. THE Load_Time_Bake SHALL complete within 500 milliseconds for a 1000×700 nominal skin at @2x resolution.
5. THE cache hit path SHALL complete within 30 milliseconds.
6. THE cache SHALL respect the existing 50 MB `.wamp` cache cap — entries exceeding the cap trigger LRU eviction.

### Requirement 9: Existing v3 Features Carry Forward Inside Interior View

**User Story:** As a skin author, I want sprite buttons, skin fonts, border/corner/shadow, and all existing v3 surface descriptors to continue working inside the interior, so that the chrome architecture change doesn't break existing skin features.

#### Acceptance Criteria

1. WHEN a chrome-mode skin is active, THE Skin_Context SHALL render v3 surface descriptors (sprite-sheet fills, font references, border/corner/shadow) inside Interior_View exactly as they render today in the full content view.
2. THE existing sprite-sheet state transitions (normal, hover, pressed), font consumption, and border/corner/shadow application SHALL function identically inside Interior_View.
3. WHEN a skin declares both `chrome` and v3 `surfaces`, THE Skin_Engine SHALL apply `chrome` for the window shape and compositing host, and `surfaces` for the interior content appearance.

### Requirement 10: Hot Reload for Chrome Mode Skins

**User Story:** As a skin author iterating on a chrome skin, I want edits to the chrome image, v3 surfaces, or animation descriptors to hot-reload within the existing debounce window, so that I get rapid visual feedback.

#### Acceptance Criteria

1. WHEN the chrome image file (`chrome@2x.png`) is modified on disk, THE Skin_Engine SHALL detect the change via FSEventStream and reload the chrome within the existing 200ms debounce window.
2. WHEN a v3 surface in a composed skin is modified, THE Skin_Engine SHALL re-bake the composed image through the Load_Time_Bake pipeline and reinstall it as `baseLayer.contents`.
3. WHEN an entry in `chrome.animations` is modified, THE Skin_Engine SHALL re-diff animated layers by `id` and swap parameters in place without restarting running timelines where possible.
4. WHEN a hot reload completes, THE MainWindowController SHALL apply the updated chrome to Chrome_Host_View and post a `.skinDidChange` notification.

### Requirement 11: Particle Emitter Animated Layer

**User Story:** As a skin author, I want to declare particle emitters in the chrome manifest (drifting sparks, steam, ambient glow dust), so that the chrome has live animated effects.

#### Acceptance Criteria

1. WHEN `chrome.animations[i].kind` equals `"particle"`, THE Skin_Engine SHALL install a `CAEmitterLayer` inside Chrome_Host_View, z-ordered by the layer's `z` value, bounded to `layer.rect`.
2. THE particle emitter SHALL use the declared `birthRate`, `lifetime`, `velocity`, `emissionAngle`, `emissionRange`, `color`, `scale`, and optional `image` from Particle_Params.
3. WHEN `particle.image` is declared, THE emitter SHALL use the referenced sprite image as the particle cell's contents.
4. WHEN `particle.image` is absent, THE emitter SHALL use a procedurally-generated soft dot.
5. THE particle emitter SHALL respect `phaseOffset` and `speedMultiplier` from the Chrome_Animation_Layer descriptor.
6. THE particle emitter SHALL be clipped to the chrome base image's alpha silhouette so particles cannot render outside the chrome shape.

### Requirement 12: LED Array Animated Layer

**User Story:** As a skin author, I want to declare LED arrays (status LEDs, equalizer ladders, power indicators) in the chrome manifest, so that the chrome has blinking indicator effects.

#### Acceptance Criteria

1. WHEN `chrome.animations[i].kind` equals `"ledArray"`, THE Skin_Engine SHALL install a `CALayer` subtree inside Chrome_Host_View, z-ordered by `z`, bounded to `layer.rect`, rendering cells per Led_Array_Params.
2. THE LED array SHALL support five pattern modes: `steady`, `blink` (with configurable hz and duty cycle), `phased` (cells light in sequence), `random` (configurable hz and density), and `marquee` (scrolling window).
3. THE LED array animation SHALL be driven by a single per-layer `CADisplayLink`-paced clock, with `phaseOffset` and `speedMultiplier` applied.
4. THE LED array SHALL build palette swatches and cell geometry once on load — no per-frame allocation.
5. THE LED array SHALL be clipped to the chrome base image's alpha silhouette.

### Requirement 13: Sprite Animation Layer

**User Story:** As a skin author, I want to declare sprite animations (rotating dials, scrolling LCD marquees, spinning records) in the chrome manifest, so that the chrome has frame-by-frame animated effects.

#### Acceptance Criteria

1. WHEN `chrome.animations[i].kind` equals `"spriteAnim"`, THE Skin_Engine SHALL install a `CALayer` inside Chrome_Host_View, z-ordered by `z`, bounded to `layer.rect`, cycling through frames of the declared sprite sheet.
2. THE sprite animation SHALL use `contentsRect` UV offsets to select frames from the sheet (same technique as Amplify v1 sprite state variants) — no per-frame image reallocation.
3. THE sprite animation SHALL advance frames based on `CACurrentMediaTime()` at the declared `fps`, with `phaseOffset` and `speedMultiplier` applied.
4. THE sprite animation SHALL support three loop modes: `loop` (repeat indefinitely), `pingPong` (reverse at ends), and `once` (stop on last frame).
5. THE sprite animation SHALL be clipped to the chrome base image's alpha silhouette.

### Requirement 14: Shader Preset Animated Layer

**User Story:** As a skin author, I want to declare named shader effects (glow, scanlines, noise) in the chrome manifest, so that the chrome has GPU-accelerated visual effects.

#### Acceptance Criteria

1. WHEN `chrome.animations[i].kind` equals `"shader"`, THE Skin_Engine SHALL install a `CAMetalLayer` inside Chrome_Host_View, z-ordered by `z`, bounded to `layer.rect`, running the built-in shader selected by `preset`.
2. THE Skin_Engine SHALL ship three shader presets in the MVP: `glow` (soft pulsing luminance), `scanlines` (CRT horizontal line overlay), and `noise` (animated film-grain overlay).
3. THE shader presets SHALL accept declarative parameters: `color` (hex), `intensity` (0…1), and `hz` (pulse frequency), each with documented defaults.
4. IF a `chrome.animations` entry references an unknown `preset` value, THEN THE Skin_Engine SHALL skip that layer, display a SkinWarningBanner naming the unknown preset, and load the rest of the skin normally.
5. THE shader preset layer SHALL be clipped to the chrome base image's alpha silhouette.

### Requirement 15: Animated Layer Clipping to Chrome Silhouette

**User Story:** As a developer, I want all animated chrome layers clipped to the static base image's alpha, so that animations cannot paint pixels outside the window shape.

#### Acceptance Criteria

1. THE Chrome_Host_View SHALL install a single shared mask (derived from the base layer's alpha) on the animated-layer container so that no animated layer renders a pixel where the chrome base image's alpha is 0.
2. FOR ALL animated layers of any kind (particle, LED array, sprite animation, shader preset), pixels rendered outside the chrome silhouette SHALL be invisible.

### Requirement 16: Animation Frame Budget

**User Story:** As a user, I want animated chrome to run at 60 fps without degrading terminal responsiveness, so that the live chrome feels smooth without impacting my work.

#### Acceptance Criteria

1. WHILE all MVP animated layers are active on a single skin, THE compositor SHALL sustain 60 fps on Apple Silicon (M1 and later) without dropping frames during normal Holoscape use (typing, scrolling, pane switches).
2. THE total compositor commit time for animated chrome layers SHALL remain at or below 8 milliseconds per frame, measured via `os_signpost`.
3. WHEN running on older hardware that cannot sustain 60 fps, THE compositor SHALL degrade gracefully with frame drops rather than correctness loss.

### Requirement 17: Density Mode Interaction with Animated Layers

**User Story:** As a user, I want density mode settings to control animated chrome behavior, so that I can reduce visual complexity or disable animations entirely.

#### Acceptance Criteria

1. WHILE Density_Mode_Manager mode is `.off`, THE Chrome_Host_View SHALL remove ALL animated chrome layers from the layer tree (zero CPU/GPU cost — layers removed, not just paused).
2. WHILE Density_Mode_Manager mode is `.minimal`, THE Chrome_Host_View SHALL pause all animated chrome layers and display them in their starting frame (visible but static).
3. WHILE Density_Mode_Manager mode is `.full`, THE Chrome_Host_View SHALL run all animated chrome layers normally.

### Requirement 18: Animated Layer Manifest Validation

**User Story:** As a skin author, I want the engine to validate my animated layer declarations at load time and tell me exactly what's wrong, so that I can fix manifest errors quickly.

#### Acceptance Criteria

1. WHEN a skin with `chrome.animations` is loaded, THE Skin_Engine SHALL validate that every `id` in the animations array is unique within the skin.
2. THE Skin_Engine SHALL validate that every animated layer's `rect` is inside the chrome bounds (`0, 0, chrome.width, chrome.height`).
3. THE Skin_Engine SHALL validate kind-specific parameters: `gridRows * gridCols >= frameCount` for sprite animations, `birthRate > 0` for particle emitters, `palette.count > 0` for LED arrays, and referenced sprite sheets and images exist within the skin bundle.
4. IF any animated layer fails validation, THEN THE Skin_Engine SHALL display a SkinWarningBanner naming the offending layer `id` and the specific validation failure, skip the invalid layer, and load the rest of the skin normally.

### Requirement 19: Malformed Chrome Graceful Fallback

**User Story:** As a user, I want a broken chrome skin to degrade gracefully to rectangular rendering without crashing, so that I can always recover to a working state.

#### Acceptance Criteria

1. IF the chrome image is missing, not RGBA, or its decoded dimensions do not match the declared `chrome.width` and `chrome.height`, THEN THE Skin_Engine SHALL display a SkinWarningBanner with a specific error message and fall back to rectangular rendering with the declared v3 surface fills.
2. IF `chrome.interiorRect` specifies a rectangle that extends outside the chrome image bounds, THEN THE Skin_Engine SHALL display a SkinWarningBanner and fall back to rectangular rendering.
3. THE Skin_Engine SHALL NOT throw unhandled exceptions during chrome loading — all errors SHALL be caught, logged, and result in graceful fallback to rectangular rendering.

### Requirement 20: Reduce Transparency Accessibility Support

**User Story:** As a user with Reduce Transparency enabled, I want the chrome to render without real transparency while preserving the shape silhouette, so that the window remains usable.

#### Acceptance Criteria

1. WHILE `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true AND `chrome.imageOpaque` is declared, THE Skin_Engine SHALL use the opaque variant image as `baseLayer.contents` instead of the standard chrome image.
2. WHILE Reduce Transparency is true AND `chrome.imageOpaque` is absent, THE Skin_Engine SHALL render the standard chrome image with alpha multiplied to 1.0 on all non-zero-alpha pixels, preserving the shape silhouette without real transparency.

### Requirement 21: Reduce Motion Accessibility Support

**User Story:** As a user with Reduce Motion enabled, I want animated chrome layers to freeze on their starting frame and chrome-swap transitions to skip animation, so that the window respects my accessibility preference.

#### Acceptance Criteria

1. WHILE macOS Reduce Motion is enabled, THE Chrome_Host_View SHALL freeze all animated chrome layers on their starting frame without hiding them.
2. WHILE macOS Reduce Motion is enabled, THE MainWindowController SHALL skip any animation during chrome-swap transitions (skin change) and apply the new chrome immediately.

### Requirement 22: HiDPI Chrome Image Support

**User Story:** As a skin author, I want to ship @2x chrome images by default with optional @1x and @3x variants, so that the chrome renders crisply on all display densities.

#### Acceptance Criteria

1. THE Skin_Engine SHALL prefer `chrome@2x.png` when loading a baked chrome image on HiDPI displays.
2. WHEN `chrome@2x.png` is absent, THE Skin_Engine SHALL fall back to `chrome.png` at 1x resolution.
3. WHEN `chrome@3x.png` is present and the display's backing scale factor matches, THE Skin_Engine SHALL load the @3x variant.

### Requirement 23: Debug Overlay for Chrome Authoring

**User Story:** As a skin author, I want a debug overlay that visualizes the chrome's alpha channel, interior rect, polygon outlines, animated layer bounds, and phase clock, so that I can iterate on my skin with full visibility into what the compositor is doing.

#### Acceptance Criteria

1. WHEN the environment variable `HOLOSCAPE_PNG_CHROME_DEBUG` is set to `"1"`, THE Chrome_Host_View SHALL render a debug overlay containing: (a) a semitransparent false-color rendering of the chrome image's alpha channel, (b) a red outline of `interiorRect`, (c) a green overlay of `windowShape.polygons`, (d) a yellow outline and `id` label for every animated layer's rect, and (e) a live clock showing current phase seconds.
2. WHEN `HOLOSCAPE_PNG_CHROME_DEBUG` is absent or not `"1"`, THE Chrome_Host_View SHALL render no debug overlay.

### Requirement 24: Chrome Data Model — Codable Descriptors

**User Story:** As a developer, I want the new chrome descriptor types to be Codable, Equatable, and Sendable, so that they integrate cleanly with the existing manifest parsing and testing infrastructure.

#### Acceptance Criteria

1. THE `ChromeDescriptor` struct SHALL include fields for `mode` (baked/composed), `image` (optional path), `imageOpaque` (optional path), `width` (Int), `height` (Int), `interiorRect` (SkinRect), `interiorPath` (optional [Polygon]), and `animations` (optional [ChromeAnimationLayer]).
2. THE `ChromeAnimationLayer` struct SHALL include fields for `id` (String), `kind` (particle/ledArray/spriteAnim/shader), `rect` (SkinRect), `z` (Int), `phaseOffset` (optional Double), `speedMultiplier` (optional Double), and `params` (discriminated by kind).
3. THE `SkinDefinition` model SHALL add an optional `chrome` property of type `ChromeDescriptor` that decodes from the `"chrome"` JSON key, with nil default for backward compatibility.
4. FOR ALL valid `ChromeDescriptor` values (including all animation kinds and parameter variants), encoding to JSON and decoding back SHALL produce an equivalent `ChromeDescriptor` object.
5. FOR ALL valid `SkinDefinition` manifests containing `chrome` alongside existing v1/v2/v3 fields, encoding then decoding SHALL produce an equivalent `SkinDefinition` object.

### Requirement 25: Backward Compatibility with Existing Skins

**User Story:** As an existing Holoscape user, I want my v2 and v3 skins to continue working without modification after PNG Chrome ships, so that the upgrade is non-breaking.

#### Acceptance Criteria

1. WHEN a skin manifest contains no `chrome` field, THE Skin_Engine SHALL treat the skin identically to pre-PNG-Chrome behavior — v2 skins render as rectangular color/gradient/image-fill skins, v3 skins render with polygon mask shapes as before.
2. THE `SkinDefinition` model SHALL add the `chrome` field as an optional property with nil default, preserving Codable backward compatibility with all existing v1/v2/v3 manifests.
3. WHEN the existing `HoloscapeSynthwave` reference skin is loaded after PNG Chrome ships, THE Skin_Engine SHALL produce rendering identical to the pre-PNG-Chrome version.

### Requirement 26: Chrome Image Size and Memory Caps

**User Story:** As a developer, I want enforced size limits on chrome images and animated sprite sheets, so that malicious or oversized skins cannot exhaust system memory.

#### Acceptance Criteria

1. THE Skin_Engine SHALL reject chrome images whose decoded dimensions exceed 4096×4096 pixels (approximately 44 MB decoded RGBA).
2. THE Skin_Engine SHALL reject animated sprite sheets whose dimensions exceed 2048×2048 pixels per sheet, with a maximum of four sheets per skin.
3. THE Skin_Engine SHALL enforce a 64 MB total GPU texture allocation cap for animated layers combined — layers that would exceed the cap SHALL be disabled with a SkinWarningBanner.
4. IF a chrome image or sprite sheet exceeds the size cap, THEN THE Skin_Engine SHALL display a SkinWarningBanner and fall back to rectangular rendering.

### Requirement 27: Asset Path Security

**User Story:** As a developer, I want all chrome asset paths validated against the skin bundle sandbox, so that a malicious skin cannot read files outside its directory.

#### Acceptance Criteria

1. THE Skin_Engine SHALL validate all chrome-related asset paths (chrome image, opaque variant, animated layer sprite images, sprite sheets) using the existing `validateAssetPath` and `assertPathResolvesInside` sandbox gates.
2. IF a chrome asset path contains `..` traversal segments, absolute path prefixes, or URL schemes, THEN THE Skin_Engine SHALL reject the path and fall back to rectangular rendering.

### Requirement 28: Accessibility — VoiceOver and Keyboard Navigation

**User Story:** As a user relying on assistive technologies, I want animated chrome layers to be marked as decorative and all interactive content to remain navigable, so that VoiceOver and keyboard navigation work correctly.

#### Acceptance Criteria

1. THE Chrome_Host_View and all animated chrome sublayers SHALL be marked with `accessibilityHidden = true` — they are decorative and not part of the interactive tree.
2. THE Interior_View and all app content subviews SHALL retain their existing accessibility labels, roles, and identifiers regardless of the active chrome skin.
3. WHEN VoiceOver is active, THE Chrome_Views inside Interior_View SHALL remain navigable and announce their accessibility titles and values as they do with the default rectangular window.

### Requirement 29: Load-Time Bake Pipeline Determinism

**User Story:** As a developer, I want the composed-mode bake pipeline to produce deterministic output for the same inputs, so that the SHA cache works correctly and tests are reproducible.

#### Acceptance Criteria

1. FOR ALL identical sets of v3 surface descriptors and referenced image bytes, THE Load_Time_Bake pipeline SHALL produce byte-identical output images.
2. THE SHA hash of the bake inputs SHALL change if and only if any surface descriptor or referenced image byte changes.
3. FOR ALL valid composed-mode skins, baking then loading the cached image SHALL produce a `CGImage` equivalent to the freshly-baked result (round-trip property).

### Requirement 30: Coordinate System Convention

**User Story:** As a skin author, I want all chrome coordinates (interior rect, animation rects, skin rects) to use top-left origin matching image editors, so that I can author skins without mental coordinate flipping.

#### Acceptance Criteria

1. THE `chrome.interiorRect`, all `ChromeAnimationLayer.rect` values, and all `SkinRect` values in the manifest SHALL use top-left origin coordinates matching PNG/image-editor convention.
2. THE Skin_Engine SHALL convert top-left-origin manifest coordinates to AppKit's bottom-left-origin coordinate system internally, without exposing the conversion to skin authors.
