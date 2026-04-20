# Implementation Plan: PNG Chrome — Winamp-class Skinning with Live Animated Chrome

## Overview

This plan implements the PNG Chrome architecture in four phases matching the PRD: static transparency foundation, animated chrome layers, reference skins + docs, and integration/verification/cleanup. Each task builds incrementally on previous tasks, with property-based tests (SwiftCheck) validating the 11 correctness properties from the design document and unit tests covering specific scenarios.

All code is Swift, targeting macOS with AppKit, Core Animation, and Metal. New files land under `Sources/Holoscape/` in the existing directory structure. Property tests go in `Tests/HoloscapePropertyTests/`, unit tests in `Tests/HoloscapeTests/Unit/`, and integration tests in `Tests/HoloscapeTests/Integration/`.

## Tasks

- [ ] 1. Phase 1 — Data model and core types
  - [ ] 1.1 Add ChromeDescriptor, SkinRect, and animation param types to AmplifyDescriptors.swift
    - Add `ChromeDescriptor` struct with `mode` (baked/composed), `image`, `imageOpaque`, `width`, `height`, `interiorRect`, `interiorPath`, `animations` fields
    - Add `SkinRect` struct with `x`, `y`, `width`, `height` (Double)
    - Add `ChromeAnimationLayer` struct with `id`, `kind`, `rect`, `z`, `phaseOffset`, `speedMultiplier`, `params`
    - Add `ParticleParams`, `LedArrayParams`, `SpriteAnimParams`, `ShaderParams` structs with all fields from the design
    - Add `LedArrayParams.Pattern` enum with `steady`, `blink`, `phased`, `random`, `marquee` cases
    - Add `LedArrayParams.LedCell` struct
    - All types must conform to `Codable`, `Equatable`, `Sendable`
    - _Requirements: 24.1, 24.2, 24.3_

  - [ ] 1.2 Add optional `chrome` property to SkinDefinition
    - Add `var chrome: ChromeDescriptor?` to `SkinDefinition` in `SkinDefinition.swift`
    - Default to nil for backward compatibility with v1/v2/v3 manifests
    - _Requirements: 24.3, 25.2_

  - [ ]* 1.3 Write property test for ChromeDescriptor and SkinDefinition v4 Codable round-trip
    - **Property 1: ChromeDescriptor and SkinDefinition v4 Codable Round-Trip**
    - Create `Tests/HoloscapePropertyTests/ChromeDescriptorRoundTripPropertyTests.swift`
    - Generate random `ChromeDescriptor` values with all animation kinds (particle, LED array, sprite animation, shader preset) and all parameter variants
    - Generate random `SkinDefinition` values containing `chrome` alongside existing v1/v2/v3 fields
    - Assert encode-then-decode produces equivalent objects
    - 100 iterations
    - **Validates: Requirements 24.4, 24.5**

  - [ ]* 1.4 Write unit tests for backward compatibility with existing skins
    - Create `Tests/HoloscapeTests/Unit/ChromeBackwardCompatTests.swift`
    - Test that v2 skin manifests without `chrome` field decode correctly with `chrome == nil`
    - Test that v3 skin manifests with `windowShape` but no `chrome` decode correctly
    - Test that existing `HoloscapeSynthwave` reference skin JSON decodes identically to pre-PNG-Chrome
    - _Requirements: 25.1, 25.2, 25.3_

- [ ] 2. Phase 1 — CoordinateConverter and ChromeValidator
  - [ ] 2.1 Implement CoordinateConverter
    - Create `Sources/Holoscape/Services/CoordinateConverter.swift`
    - Implement `static func toAppKit(_ rect: SkinRect, chromeHeight: Double) -> CGRect` converting top-left origin to AppKit bottom-left origin
    - Implement `static func toAppKit(x: Double, y: Double, chromeHeight: Double) -> CGPoint`
    - Formula: `y_appkit = chromeHeight - y_manifest - rect.height`
    - _Requirements: 30.1, 30.2_

  - [ ]* 2.2 Write property test for coordinate conversion correctness
    - **Property 7: Coordinate Conversion Correctness**
    - Create `Tests/HoloscapePropertyTests/CoordinateConversionPropertyTests.swift`
    - Generate random `SkinRect` values and positive chrome heights
    - Assert `y_appkit = chromeHeight - y_manifest - rect.height`
    - Assert round-trip: convert to AppKit then back to manifest produces original SkinRect
    - 100 iterations
    - **Validates: Requirements 30.1, 30.2**

  - [ ] 2.3 Implement ChromeValidator
    - Create `Sources/Holoscape/Services/ChromeValidator.swift`
    - Implement `crossCheckPolygonVsAlpha(polygonBBox:alphaBBox:tolerance:)` — returns warning string if bounding boxes differ by more than 2px on any edge
    - Implement `validateAnimations(_:chromeBounds:skinDir:images:)` — returns per-layer validation results: reject duplicate ids, out-of-bounds rects, invalid kind-specific params
    - Implement `validateInteriorRect(_:chromeBounds:)` — returns warning if interiorRect extends outside chrome bounds
    - Implement `validateImageSize(width:height:maxDimension:)` — rejects images exceeding 4096×4096
    - Implement `validateSpriteSheets(sheets:maxDimension:maxSheets:)` — rejects sheets exceeding 2048×2048 or more than 4 sheets
    - All functions are pure/static with no side effects
    - _Requirements: 5.1, 5.2, 5.3, 18.1, 18.2, 18.3, 18.4, 19.2, 26.1, 26.2, 26.3_

  - [ ]* 2.4 Write property test for polygon vs chrome alpha bounds cross-check
    - **Property 2: Polygon vs Chrome Alpha Bounds Cross-Check**
    - Create `Tests/HoloscapePropertyTests/ChromePolygonAlphaCrossCheckPropertyTests.swift`
    - Generate random CGRect pairs with varying offsets
    - Assert warning returned if and only if bounding boxes differ by more than 2px on any edge
    - Assert no warning when within tolerance
    - 100 iterations
    - **Validates: Requirements 5.1, 5.2, 5.3**

  - [ ]* 2.5 Write property test for animated layer manifest validation
    - **Property 3: Animated Layer Manifest Validation**
    - Create `Tests/HoloscapePropertyTests/ChromeAnimationValidationPropertyTests.swift`
    - Generate random `ChromeAnimationLayer` arrays with valid/invalid params
    - Assert duplicate ids rejected, out-of-bounds rects rejected, invalid kind-specific params rejected (gridRows*gridCols < frameCount, birthRate <= 0, palette.count == 0, missing sprite sheets)
    - Assert all valid layers accepted
    - 100 iterations
    - **Validates: Requirements 18.1, 18.2, 18.3**

  - [ ]* 2.6 Write property test for chrome image and sprite sheet size cap validation
    - **Property 8: Chrome Image and Sprite Sheet Size Cap Validation**
    - Create `Tests/HoloscapePropertyTests/ChromeSizeCapPropertyTests.swift`
    - Generate random image dimensions
    - Assert images exceeding 4096×4096 rejected, within cap accepted
    - Assert sprite sheets exceeding 2048×2048 rejected, sets with more than 4 sheets rejected
    - 100 iterations
    - **Validates: Requirements 26.1, 26.2**

  - [ ]* 2.7 Write property test for chrome asset path sandboxing
    - **Property 11: Chrome Asset Path Sandboxing**
    - Create `Tests/HoloscapePropertyTests/ChromePathSandboxPropertyTests.swift`
    - Generate random paths with/without `..` traversal segments, absolute path prefixes, URL schemes
    - Assert paths with traversal/absolute/URL rejected; clean relative paths accepted
    - 100 iterations
    - **Validates: Requirements 27.1, 27.2**

  - [ ]* 2.8 Write unit tests for ChromeValidator edge cases
    - Create `Tests/HoloscapeTests/Unit/ChromeValidatorTests.swift`
    - Test all error conditions from the design's error handling table
    - Test interiorRect validation (inside bounds, outside bounds, partially outside)
    - Test animation validation with each kind's specific failure modes
    - _Requirements: 5.1, 5.2, 18.1, 18.2, 18.3, 18.4, 19.2, 26.1, 26.2, 26.3_

- [ ] 3. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Phase 1 — ChromeHostView and InteriorView
  - [ ] 4.1 Implement ChromeHostView
    - Create `Sources/Holoscape/Views/ChromeHostView.swift`
    - `@MainActor final class ChromeHostView: NSView` with `wantsLayer = true`
    - Add `baseLayer: CALayer` for the static chrome image (alpha IS the window shape)
    - Add `animationContainer: CALayer` with a shared mask derived from baseLayer's alpha for animation clipping
    - Add `animatedLayers: [String: CALayer]` dictionary keyed by manifest id
    - Implement `installBaseImage(_:scale:)` — set `baseLayer.contents`, configure `contentsScale`
    - Implement `installAnimations(_:skinDir:images:)` — build appropriate CALayer subclass per kind, z-order by `z`
    - Implement `updateAnimations(_:skinDir:images:)` — diff by id: add new, remove old, update changed params
    - Implement `removeAllAnimations()` — density mode `.off`
    - Implement `pauseAllAnimations()` — density mode `.minimal`, freeze on starting frame
    - Implement `resumeAllAnimations()` — density mode `.full`
    - Mark `accessibilityHidden = true` on self and all animated sublayers
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 15.1, 15.2, 17.1, 17.2, 17.3, 28.1_

  - [ ] 4.2 Implement InteriorView
    - Create `Sources/Holoscape/Views/InteriorView.swift`
    - `@MainActor final class InteriorView: NSView`
    - Implement `installInteriorMask(from path: [Polygon]?)` — install `CAShapeLayer` mask for concave interiors, no-op for nil (convex)
    - Use own bounds as layout coordinate space: `(0, 0, interiorRect.width, interiorRect.height)`
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [ ] 4.3 Implement debug overlay on ChromeHostView
    - Implement `installDebugOverlay(interiorRect:polygons:animationRects:)` — render when `HOLOSCAPE_PNG_CHROME_DEBUG=1`
    - Overlay includes: (a) semitransparent false-color alpha channel, (b) red outline of interiorRect, (c) green overlay of windowShape.polygons, (d) yellow outline + id label for animated layer rects, (e) live phase clock
    - No-op when env var is absent or not "1"
    - _Requirements: 23.1, 23.2_

  - [ ]* 4.4 Write unit tests for ChromeHostView and InteriorView
    - Create `Tests/HoloscapeTests/Unit/ChromeHostViewTests.swift`
    - Test base layer install, animation container mask presence, z-ordering of animated layers, debug overlay presence/absence
    - Create `Tests/HoloscapeTests/Unit/InteriorViewTests.swift`
    - Test frame pinning to interiorRect, concave mask installation, convex no-mask, subview reparenting
    - _Requirements: 1.1, 3.1, 3.2, 3.3, 3.4, 23.1, 23.2, 28.1_

- [ ] 5. Phase 1 — Load-time bake pipeline
  - [ ] 5.1 Implement ChromeBakePipeline
    - Create `Sources/Holoscape/Services/ChromeBakePipeline.swift`
    - Implement `bake(surfaces:images:width:height:scale:)` — walk v3 surfaces, draw into CGContext at `(width*2, height*2)` for @2x, produce RGBA CGImage
    - Implement `inputHash(surfaces:imageBytes:)` — SHA-256 of bake inputs for cache keying
    - Implement `loadCached(sha:)` — load cached bake result from `~/Library/Caches/holoscape-skins/<sha>.png`
    - Implement `saveToCache(_:sha:)` — save bake result to cache directory
    - Cache respects existing 50 MB `.wamp` cache cap with LRU eviction
    - Bake must complete within 500ms for 1000×700 nominal skin at @2x; cache hit within 30ms
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 29.1, 29.2, 29.3_

  - [ ]* 5.2 Write property test for bake pipeline determinism and cache round-trip
    - **Property 6: Bake Pipeline Determinism and Cache Round-Trip**
    - Create `Tests/HoloscapePropertyTests/ChromeBakeDeterminismPropertyTests.swift`
    - Generate random surface descriptor sets and image bytes
    - Assert identical inputs produce byte-identical output images
    - Assert SHA changes if and only if any input changes
    - Assert bake → save → load produces equivalent CGImage
    - 25 iterations (disk I/O)
    - **Validates: Requirements 29.1, 29.2, 29.3**

  - [ ]* 5.3 Write unit tests for bake pipeline
    - Create `Tests/HoloscapeTests/Unit/ChromeBakePipelineTests.swift`
    - Test composed bake output for known surface inputs
    - Test SHA cache hit and miss paths
    - Test cache invalidation on input change
    - Test performance budget (500ms bake, 30ms cache hit)
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

- [ ] 6. Phase 1 — SkinEngine chrome-mode branch and HiDPI resolution
  - [ ] 6.1 Extend SkinEngine with chrome loading and HiDPI resolution
    - Add `resolveHiDPIImage(basePath:skinDir:backingScale:)` to `SkinEngine` — prefer `chrome@2x.png`, fall back to `chrome.png` at 1x, optionally load `chrome@3x.png` on matching scale
    - Extend `loadComposite(named:)` with chrome-mode branch: when `chrome` field present, decode/bake chrome image, validate via ChromeValidator, build `LoadedSkin` with chrome data
    - Add chrome image alpha bounds sampling for polygon cross-check
    - Enforce size caps for chrome images (4096×4096) and sprite sheets (2048×2048, max 4)
    - Enforce 64 MB total GPU texture allocation cap for animated layers
    - Add `chrome: ChromeDescriptor?`, `chromeImage: CGImage?`, `chromeImageOpaque: CGImage?` to `LoadedSkin`
    - _Requirements: 1.1, 1.2, 7.1, 7.2, 7.3, 8.1, 22.1, 22.2, 22.3, 26.1, 26.2, 26.3, 26.4, 27.1, 27.2_

  - [ ]* 6.2 Write property test for HiDPI image resolution selection
    - **Property 10: HiDPI Image Resolution Selection**
    - Create `Tests/HoloscapePropertyTests/ChromeHiDPISelectionPropertyTests.swift`
    - Generate random combinations of available image variants (presence/absence of chrome.png, chrome@2x.png, chrome@3x.png) and backing scale factors
    - Assert highest-resolution matching variant selected; chrome.png fallback when only 1x available; nil when no variant available
    - 100 iterations
    - **Validates: Requirements 7.2, 22.1, 22.2, 22.3**

- [ ] 7. Phase 1 — MainWindowController chrome integration
  - [ ] 7.1 Implement chrome-mode window configuration in MainWindowController
    - Add `applyChrome(_:)` method — when `chrome` is present: configure window as borderless (`styleMask: [.borderless, .fullSizeContentView]`), `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`
    - Set `contentMinSize` and `contentMaxSize` both equal to `(chrome.width, chrome.height)`, strip `.resizable`
    - Install `ChromeHostView` as full-bounds child of `ShapedContentView`
    - Create `InteriorView` pinned to `chrome.interiorRect` (converted via CoordinateConverter)
    - Reparent all existing app content subviews (terminal, sidebar, tab bar, input box, session launcher, chrome bands) under `InteriorView`
    - Set `window.isMovableByWindowBackground = true`
    - Remove `WindowDragOverlay` when chrome mode is active
    - Honor explicit `dragRegions` from manifest as in Amplify v1
    - _Requirements: 1.3, 1.6, 2.1, 2.2, 3.1, 3.2, 3.5, 6.1, 6.2, 6.3_

  - [ ] 7.2 Implement teardownChrome and non-chrome fallback
    - Add `teardownChrome()` method — reverse chrome setup when switching to non-chrome skin: restore titled/resizable window, reparent subviews back to content view, remove ChromeHostView and InteriorView
    - When `chrome` field is absent, retain existing window configuration with no behavior change
    - _Requirements: 1.6, 2.2, 3.5, 25.1_

  - [ ] 7.3 Implement malformed chrome graceful fallback
    - When chrome image is missing, not RGBA, or dimensions mismatch: display SkinWarningBanner, fall back to rectangular rendering with v3 surface fills
    - When `interiorRect` extends outside chrome bounds: display SkinWarningBanner, fall back to rectangular rendering
    - No unhandled exceptions during chrome loading — all errors caught, logged, and result in graceful fallback
    - _Requirements: 19.1, 19.2, 19.3_

  - [ ] 7.4 Implement Reduce Transparency support
    - When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true and `chrome.imageOpaque` is declared: use opaque variant image
    - When Reduce Transparency is true and `chrome.imageOpaque` is absent: render chrome image with alpha multiplied to 1.0 on all non-zero-alpha pixels
    - _Requirements: 20.1, 20.2_

  - [ ]* 7.5 Write property test for chrome loading robustness
    - **Property 9: Chrome Loading Robustness**
    - Create `Tests/HoloscapePropertyTests/ChromeLoadingRobustnessPropertyTests.swift`
    - Generate random/malformed `ChromeDescriptor` values (missing images, non-RGBA, dimension mismatches, out-of-bounds interior rects, invalid animation params)
    - Assert chrome loading pipeline either produces valid chrome configuration or falls back to rectangular rendering — never throws unhandled exception or crashes
    - 100 iterations
    - **Validates: Requirements 19.2, 19.3**

  - [ ]* 7.6 Write unit tests for window configuration and chrome integration
    - Create `Tests/HoloscapeTests/Unit/ChromeWindowConfigTests.swift`
    - Test borderless transition, fixed size, clear bg, no shadow, revert on non-chrome skin
    - Create `Tests/HoloscapeTests/Unit/ChromeDragTests.swift`
    - Test isMovableByWindowBackground, WindowDragOverlay removal, explicit dragRegions honored
    - Create `Tests/HoloscapeTests/Unit/ChromeReduceTransparencyTests.swift`
    - Test opaque variant selection, alpha multiplication fallback
    - _Requirements: 1.3, 1.6, 2.1, 6.1, 6.2, 6.3, 19.1, 19.2, 20.1, 20.2_

- [ ] 8. Phase 1 — Hot reload and hit testing
  - [ ] 8.1 Extend hot reload for chrome-mode skins
    - When chrome image file is modified on disk: detect via FSEventStream, reload within 200ms debounce
    - When v3 surface in composed skin is modified: re-bake via ChromeBakePipeline, reinstall as baseLayer.contents
    - When `chrome.animations` entry is modified: re-diff animated layers by id, swap params in place without restarting running timelines where possible
    - Post `.skinDidChange` notification after hot reload completes
    - _Requirements: 10.1, 10.2, 10.3, 10.4_

  - [ ] 8.2 Verify hit testing works with chrome-mode skins
    - Ensure `ShapedContentView` continues to use `HitRegionSampler` with `windowShape.polygons` for click-through
    - No alpha sampling of chrome image — polygon point-in-polygon tester is used
    - Default rectangular hit-test when no `windowShape` declared
    - _Requirements: 4.1, 4.2, 4.3_

  - [ ]* 8.3 Write unit tests for hot reload and hit testing
    - Create `Tests/HoloscapeTests/Unit/ChromeHotReloadTests.swift`
    - Test image change triggers reload, surface change triggers re-bake, animation diff by id
    - _Requirements: 10.1, 10.2, 10.3, 10.4_

- [ ] 9. Checkpoint — Phase 1 complete, ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 10. Phase 2 — Sprite animation clock and LED pattern clock
  - [ ] 10.1 Implement SpriteAnimationClock
    - Create `Sources/Holoscape/Services/SpriteAnimationClock.swift`
    - Implement `static func frameIndex(elapsedTime:fps:frameCount:loop:phaseOffset:speedMultiplier:)` — pure function returning frame index in `[0, frameCount)`
    - For `loop` mode: cycle indefinitely
    - For `pingPong` mode: reverse at sequence ends
    - For `once` mode: clamp to `frameCount - 1` after first complete pass
    - Implement `static func contentsRect(frameIndex:gridRows:gridCols:sheetWidth:sheetHeight:cellWidth:cellHeight:)` — compute UV rect within unit square
    - _Requirements: 13.2, 13.3, 13.4_

  - [ ]* 10.2 Write property test for sprite animation frame index computation
    - **Property 4: Sprite Animation Frame Index Computation**
    - Create `Tests/HoloscapePropertyTests/SpriteAnimationClockPropertyTests.swift`
    - Generate random valid sprite animation parameters (positive fps, positive frameCount, any loop mode) and non-negative elapsed times
    - Assert frame index always in `[0, frameCount)`
    - Assert loop mode cycles, pingPong reverses at ends, once clamps to frameCount-1
    - Assert contentsRect origin and size within unit square `[0, 1]`
    - 100 iterations
    - **Validates: Requirements 13.2, 13.3, 13.4**

  - [ ] 10.3 Implement LedPatternClock
    - Create `Sources/Holoscape/Services/LedPatternClock.swift`
    - Implement `static func cellStates(cells:pattern:elapsedTime:phaseOffset:speedMultiplier:)` — pure function returning palette index array
    - Support all five pattern modes: `steady`, `blink` (hz + duty cycle), `phased` (sequential), `random` (hz + density), `marquee` (scrolling window)
    - All returned palette indices must be valid indices into the palette array
    - Deterministic: identical inputs produce identical outputs
    - _Requirements: 12.2_

  - [ ]* 10.4 Write property test for LED pattern state determinism
    - **Property 5: LED Pattern State Determinism**
    - Create `Tests/HoloscapePropertyTests/LedPatternDeterminismPropertyTests.swift`
    - Generate random LED array configurations (positive cell count, non-empty palette, any pattern mode) and time values
    - Assert two calls with identical inputs return identical palette index arrays
    - Assert all returned palette indices are valid indices into the palette array
    - 100 iterations
    - **Validates: Requirements 12.2**

- [ ] 11. Phase 2 — Particle emitter animated layer
  - [ ] 11.1 Implement particle emitter layer installation in ChromeHostView
    - When `chrome.animations[i].kind == "particle"`: install a `CAEmitterLayer` inside ChromeHostView
    - Z-order by the layer's `z` value, bounded to `layer.rect` (converted via CoordinateConverter)
    - Configure emitter with `birthRate`, `lifetime`, `lifetimeRange`, `velocity`, `velocityRange`, `emissionAngle`, `emissionRange`, `color`, `colorRange`, `scale`, `scaleRange` from ParticleParams
    - When `particle.image` is declared: use referenced sprite image as particle cell contents
    - When `particle.image` is absent: use procedurally-generated soft dot
    - Apply `phaseOffset` and `speedMultiplier` from ChromeAnimationLayer
    - Support `blendMode` (normal, additive, screen)
    - Clip to chrome base image's alpha silhouette via the shared animation container mask
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 15.1_

  - [ ]* 11.2 Write unit tests for particle emitter layer
    - Create `Tests/HoloscapeTests/Unit/ParticleLayerTests.swift`
    - Test CAEmitterLayer params match manifest values
    - Test image vs soft dot particle cell contents
    - Test phaseOffset and speedMultiplier application
    - Test blend mode configuration
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

- [ ] 12. Phase 2 — LED array animated layer
  - [ ] 12.1 Implement LED array layer installation in ChromeHostView
    - When `chrome.animations[i].kind == "ledArray"`: install a `CALayer` subtree inside ChromeHostView
    - Z-order by `z`, bounded to `layer.rect`
    - Render cells per `LedArrayParams`: cell size, cell positions, palette colors
    - Support all five pattern modes: `steady`, `blink`, `phased`, `random`, `marquee`
    - Drive animation via a single per-layer `CADisplayLink`-paced clock using `LedPatternClock`
    - Apply `phaseOffset` and `speedMultiplier`
    - Build palette swatches and cell geometry once on load — no per-frame allocation
    - Clip to chrome base image's alpha silhouette
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5_

  - [ ]* 12.2 Write unit tests for LED array layer
    - Create `Tests/HoloscapeTests/Unit/LedLayerTests.swift`
    - Test all five pattern modes produce expected cell states
    - Test palette application to cell layers
    - Test cell geometry built once (no per-frame allocation)
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

- [ ] 13. Phase 2 — Sprite animation layer
  - [ ] 13.1 Implement sprite animation layer installation in ChromeHostView
    - When `chrome.animations[i].kind == "spriteAnim"`: install a `CALayer` inside ChromeHostView
    - Z-order by `z`, bounded to `layer.rect`
    - Load sprite sheet from `sheet` path within skin bundle (validated via existing sandbox gates)
    - Use `contentsRect` UV offsets to select frames (same technique as Amplify v1 sprite state variants) — no per-frame image reallocation
    - Advance frames using `SpriteAnimationClock.frameIndex` based on `CACurrentMediaTime()` at declared `fps`
    - Apply `phaseOffset` and `speedMultiplier`
    - Support three loop modes: `loop`, `pingPong`, `once`
    - Clip to chrome base image's alpha silhouette
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5_

  - [ ]* 13.2 Write unit tests for sprite animation layer
    - Create `Tests/HoloscapeTests/Unit/SpriteAnimLayerTests.swift`
    - Test contentsRect UV computation for known frame indices
    - Test loop, pingPong, once modes
    - Test frame advancement timing
    - _Requirements: 13.1, 13.2, 13.3, 13.4_

- [ ] 14. Phase 2 — Shader preset animated layer
  - [ ] 14.1 Implement shader preset layer installation in ChromeHostView
    - When `chrome.animations[i].kind == "shader"`: install a `CAMetalLayer` inside ChromeHostView
    - Z-order by `z`, bounded to `layer.rect`
    - Ship three Metal shader presets compiled at app build time: `glow` (soft pulsing luminance), `scanlines` (CRT horizontal line overlay), `noise` (animated film-grain overlay)
    - Create Metal shader source files in `Sources/Holoscape/Resources/` for each preset
    - Each preset accepts declarative parameters: `color` (hex), `intensity` (0…1), `hz` (pulse frequency) with documented defaults
    - If unknown `preset` value: skip layer, display SkinWarningBanner, load rest of skin normally
    - Clip to chrome base image's alpha silhouette
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5_

  - [ ]* 14.2 Write unit tests for shader preset layer
    - Create `Tests/HoloscapeTests/Unit/ShaderPresetLayerTests.swift`
    - Test glow, scanlines, noise preset installation
    - Test unknown preset fallback (skip + banner)
    - Test parameter defaults applied when not specified
    - _Requirements: 14.1, 14.2, 14.3, 14.4_

- [ ] 15. Phase 2 — Animation clipping, density mode, and Reduce Motion
  - [ ] 15.1 Implement animation silhouette clipping
    - Install a single shared mask (derived from base layer's alpha) on the animated-layer container in ChromeHostView
    - Ensure no animated layer of any kind renders a pixel where chrome base image's alpha is 0
    - _Requirements: 15.1, 15.2_

  - [ ] 15.2 Implement density mode interaction with animated layers
    - Extend density mode observer in MainWindowController to manage animated layer lifecycle
    - `.off`: call `ChromeHostView.removeAllAnimations()` — remove ALL animated layers from layer tree (zero CPU/GPU cost)
    - `.minimal`: call `ChromeHostView.pauseAllAnimations()` — pause all animated layers, display starting frame (visible but static)
    - `.full`: call `ChromeHostView.resumeAllAnimations()` — run all animated layers normally
    - _Requirements: 17.1, 17.2, 17.3_

  - [ ] 15.3 Implement Reduce Motion support for animated chrome
    - When macOS Reduce Motion is enabled: freeze all animated chrome layers on their starting frame without hiding them
    - Skip any animation during chrome-swap transitions (skin change) — apply new chrome immediately
    - _Requirements: 21.1, 21.2_

  - [ ]* 15.4 Write unit tests for density mode and accessibility
    - Create `Tests/HoloscapeTests/Unit/ChromeDensityTests.swift`
    - Test `.off` removes layers from tree, `.minimal` freezes on frame 0, `.full` runs normally
    - Test transitions between density modes
    - Create `Tests/HoloscapeTests/Unit/ChromeReduceMotionTests.swift`
    - Test freeze on starting frame, skip chrome-swap animation
    - Create `Tests/HoloscapeTests/Unit/ChromeAccessibilityTests.swift`
    - Test `accessibilityHidden = true` on ChromeHostView and all animated sublayers
    - Test accessibility labels preserved on InteriorView content
    - _Requirements: 17.1, 17.2, 17.3, 21.1, 21.2, 28.1, 28.2, 28.3_

- [ ] 16. Phase 2 — Animation frame budget validation
  - [ ] 16.1 Add os_signpost instrumentation for animation frame budget
    - Instrument the compositor commit phase with `os_signpost` regions
    - Verify total compositor commit time for animated chrome layers stays at or below 8ms per frame
    - Ensure 60 fps sustained on Apple Silicon (M1+) with all MVP animated layers active
    - Graceful degradation on older hardware (frame drops, not correctness loss)
    - _Requirements: 16.1, 16.2, 16.3_

- [ ] 17. Checkpoint — Phase 2 complete, ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 18. Phase 3 — Reference skins and documentation
  - [ ] 18.1 Create HoloscapeClassic-live reference skin
    - Create skin directory under `Sources/Holoscape/Resources/Skins/HoloscapeClassic-live/`
    - Paint industrial-chrome base PNG (`chrome@2x.png`) with brushed metal, rivets, portholes aesthetic
    - Declare `skin.json` with `chrome` field (mode: baked), `interiorRect`, `windowShape.polygons`
    - Add all four animated layer kinds: particle emitter (drifting sparks in porthole), LED array (status LEDs above tab bar), sprite animation (scrolling LCD marquee), shader preset (ambient glow)
    - This is the "cooler than Winamp" demo skin
    - _Requirements: 1.1, 9.1, 9.2, 9.3_

  - [ ] 18.2 Migrate HoloscapeSynthwave to composed mode
    - Update HoloscapeSynthwave skin to use `chrome.mode: "composed"` with existing v3 surfaces
    - Add subtle ambient particles + scanlines shader as optional animations
    - Verify rendering is identical to pre-PNG-Chrome version (modulo new animations)
    - _Requirements: 8.1, 25.3_

  - [ ] 18.3 Create chrome format documentation and template
    - Create `docs/chrome-format.md` — skin-author reference covering static + animated primitives
    - Document baked vs composed authoring flows
    - Document animated layer vocabulary with decision table (which kind for which effect)
    - Include worked animated-layer recipes from HoloscapeClassic-live
    - Create chrome template asset (`docs/chrome-template.png`) with interior rect drawn as semitransparent rectangle

- [ ] 19. Phase 4 — Integration tests
  - [ ] 19.1 Write integration tests for backward compatibility and chrome paths
    - Create `Tests/HoloscapeTests/Integration/ChromeIntegrationTests.swift`
    - Test HoloscapeSynthwave backward-compat: load before and after PNG Chrome, compare chrome output
    - Test composed-with-animations round-trip: v4 composed skin with all four animation kinds
    - Test hot reload end-to-end: edit chrome image on disk, verify reload within 200ms debounce
    - Test dual Metal layer: shader preset chrome animation running while terminal Metal shader is active
    - Extend existing `BackwardCompatIntegrationTests` to cover v4 composed and baked paths
    - _Requirements: 9.1, 9.2, 9.3, 10.1, 25.1, 25.3_

  - [ ]* 19.2 Write integration test for live transparency verification
    - Create `Tests/HoloscapeTests/Integration/ChromeTransparencyTests.swift`
    - Screenshot over known-bright backdrop, sample cut-corner pixel for transparency
    - Verify alpha < 1.0 pixels produce commensurate window transparency
    - _Requirements: 1.4, 1.5_

- [ ] 20. Phase 4 — Debug overlay and cleanup
  - [ ] 20.1 Verify debug overlay end-to-end
    - Test `HOLOSCAPE_PNG_CHROME_DEBUG=1` renders all overlay components (alpha visualization, interiorRect outline, polygon overlay, animated layer bounds, phase clock)
    - Test env var absent renders no overlay
    - _Requirements: 23.1, 23.2_

  - [ ] 20.2 Remove old content-view mask path
    - Remove `ShapedWindowController.buildMaskLayer` for content-view mask (moves to InteriorView for concave interiors only)
    - Remove `writeShapeDiagnostic` if present
    - Keep `HitRegionSampler` (polygon hit testing survives)
    - Only after all in-tree shaped skins pass on v4 with animations
    - _Requirements: 1.1, 4.1_

- [ ] 21. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation at phase boundaries
- Property tests validate the 11 universal correctness properties from the design document using SwiftCheck
- Unit tests validate specific scenarios, edge cases, and integration points
- The phased approach matches the PRD's 4-phase MVP structure: static foundation → animated layers → reference skins → integration/cleanup
- All new code is Swift with `@MainActor` isolation where needed, consistent with the existing codebase
- Property tests use 100 iterations by default, 25 for disk I/O-heavy tests (bake pipeline)
