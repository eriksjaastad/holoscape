# Implementation Plan: PNG-Alpha Chrome with Animated Compositing Host

## Overview

This plan breaks the chrome architecture into 20 task groups aligned 1-to-1 with the 20 PRs in PRD §12. Language is Swift 6 / AppKit targeting macOS 15+ on Apple Silicon. Models live in `Sources/Holoscape/Models/`, services in `Sources/Holoscape/Services/`, controllers in `Sources/Holoscape/Controllers/`, views in `Sources/Holoscape/Views/`. Unit tests live in `Tests/HoloscapeTests/Unit/`, property tests in `Tests/HoloscapePropertyTests/` (flat SwiftCheck layout), integration tests in `Tests/HoloscapeTests/Integration/`. Fixtures ship under `Tests/Fixtures/Chrome/`.

Four phases:
- **Phase 1 — Static transparency foundation (PRs 1–9)**: task groups 1–9
- **Phase 2 — Animated chrome layers (PRs 10–13)**: task groups 10–13
- **Phase 3 — Reference skins + docs (PRs 14–17)**: task groups 14–17
- **Phase 4 — Integration, verification, cleanup (PRs 18–20)**: task groups 18–20

Checkpoints appear between each PR as "ensure tests pass and the relevant backward-compat scenario still renders." Old-path deletion lands only in task group 20 (PR #20), after every in-tree shaped skin has migrated to v4 with animations verified live.

## Tasks

- [ ] 1. PR #1 — End-to-end transparency prototype (Risk #1 mitigation)
  - [ ] 1.1 Minimal ChromeHostView prototype installing a known-good alpha PNG
    - Create `Sources/Holoscape/Views/ChromeHostView.swift` with just enough implementation to assign a passed `CGImage` to `layer.contents` and fill the content view bounds
    - Create `Tools/chrome_prototype/known_good_alpha.png` — a 1000×700 RGBA PNG with cut corners (pixel-verified alpha == 0 at corners, alpha == 1 in center)
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to add a temporary `HOLOSCAPE_PNG_CHROME_PROTOTYPE=1` env flag that swaps in `ChromeHostView` with the fixture image, configures the window as `.borderless`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`
    - Run on laptop against a bright desktop backdrop; visually confirm cut corners reveal the desktop
    - _Requirements: 3.1, 3.2, 3.3, 3.5_

  - [ ] 1.2 Manual visual verification checklist
    - Document the laptop visual check procedure in `docs/chrome-prototype-verification.md` — take before/after screenshots, note the desktop pattern visible through cut corners, confirm click-through works at corners
    - Gate: subsequent PRs do not land until this verification completes. Not optional.
    - _Requirements: 3.1, 3.2_

- [ ] 2. Checkpoint
  - Ensure the prototype renders transparent cut corners on the laptop. Do not proceed to subsequent PRs until Erik confirms visual transparency. No tests change here — this is a load-bearing assumption check.

- [ ] 3. PR #2 — Data model for Chrome v4
  - [ ] 3.1 Add ChromeDescriptor, SkinRect, ChromeAnimationLayer, and per-kind params to AmplifyDescriptors.swift
    - Modify `Sources/Holoscape/Models/AmplifyDescriptors.swift` to add `ChromeDescriptor`, `SkinRect`, `ChromeAnimationLayer`, `ParticleParams`, `LedArrayParams`, `SpriteAnimParams`, `ShaderParams` per the design's Data Models section
    - All types `Codable, Equatable, Sendable`
    - `ChromeDescriptor.Mode` enum with `.baked, .composed`; `ChromeAnimationLayer.Kind` enum with `.particle, .ledArray, .spriteAnim, .shader`
    - `LedArrayParams.Pattern` enum with associated values (Codable via discriminator)
    - _Requirements: 1.1, 1.4, 1.5, 1.7_

  - [ ] 3.2 Extend SkinDefinition with the v4 chrome field
    - Modify `Sources/Holoscape/Models/SkinDefinition.swift` to add optional `chrome: ChromeDescriptor?`
    - v2/v3 manifests without `chrome` decode identically to today
    - Document in the struct comment that `chrome` is v4
    - Enforce at decode or validator time that `mode == .baked` requires a non-nil `image` path (Requirement 1.2)
    - _Requirements: 1.1, 1.2, 1.6, 16.1_

  - [ ]* 3.3 Unit tests for Codable round-trips
    - Create `Tests/HoloscapeTests/Unit/ChromeDescriptorCodableTests.swift`
    - Test `ChromeDescriptor` round-trips for both modes
    - Test each `ChromeAnimationLayer.Kind` round-trips with its params
    - Test `LedArrayParams.Pattern` with each associated-value case
    - Test v2/v3 manifests decode with `chrome == nil`
    - _Requirements: 1.1, 1.4, 1.5, 1.6_

  - [ ]* 3.4 Property test: ChromeDescriptor Codable determinism
    - **Property 5 (sub-property): Codable round-trip determinism**
    - **Validates: Requirements 1.1, 1.4, 1.5**
    - Create `Tests/HoloscapePropertyTests/ChromeDescriptorCodablePropertyTests.swift`
    - Generate arbitrary `ChromeDescriptor` values via SwiftCheck; encode+decode+re-encode; assert byte-identical

- [ ] 4. Checkpoint
  - Ensure `swift test` green; ensure `HoloscapeSynthwave` + `HoloscapeClassic` + `AmplifyDemo` continue to load (none declare `chrome` yet, so they route through the pre-v4 path).

- [ ] 5. PR #3 — ChromeHostView and InteriorView
  - [ ] 5.1 Promote the prototype ChromeHostView to production
    - Modify `Sources/Holoscape/Views/ChromeHostView.swift` per the design's Component 1 interface
    - `baseLayer` as a private `CALayer`; `animatedLayersContainer` as a private `CALayer` (empty in this PR)
    - `init(chrome: ChromeDescriptor, baseImage: CGImage, clock: SharedAnimationClock)` — but `clock` parameter accepts nil since SharedAnimationClock isn't built yet; stub with `// TODO PR #11`
    - `override var isFlipped: Bool { true }` for top-left coordinate matching
    - `override func hitTest(_ point: NSPoint) -> NSView? { nil }` so ChromeHostView never receives events
    - _Requirements: 2.1, 2.2, 2.5, 2.7_

  - [ ] 5.2 Create InteriorView
    - Create `Sources/Holoscape/Views/InteriorView.swift` per the design's Component 2 interface
    - `init(rect: SkinRect, interiorPath: [Polygon]?)`
    - `override func layout()` that asserts `frame == computedFrameFromInteriorRect`
    - Install `CAShapeLayer` mask from `interiorPath` when non-nil; leave mask nil when nil
    - _Requirements: 2.3, 2.6, 2.7, 2.8_

  - [ ]* 5.3 Unit tests for ChromeHostView
    - Create `Tests/HoloscapeTests/Unit/ChromeHostViewTests.swift`
    - Test `baseLayer.contents` set to the passed `CGImage`
    - Test `hitTest(_:)` returns nil regardless of input
    - Test `animatedLayersContainer` is installed as a sibling of `baseLayer` in correct z-order (above base)
    - _Requirements: 2.1, 2.2, 2.5_

  - [ ]* 5.4 Unit tests for InteriorView
    - Create `Tests/HoloscapeTests/Unit/InteriorViewTests.swift`
    - Test frame equals `interiorRect` after layout (with top-left-to-AppKit conversion)
    - Test `interiorPath` non-nil installs `CAShapeLayer` mask
    - Test `interiorPath` nil leaves `layer.mask` as nil
    - _Requirements: 2.3, 2.6, 2.7, 2.8_

  - [ ]* 5.5 Property test: Subview addition cannot break shape
    - **Property 1: Subview addition cannot break window shape**
    - **Validates: Requirements 2.4, 2.5**
    - Create `Tests/HoloscapePropertyTests/ChromeSubviewInvariantPropertyTests.swift`
    - Generate arbitrary NSView subtrees added as children of `InteriorView`; assert `baseLayer` composited alpha is unchanged across every addition

  - [ ]* 5.6 Property test: InteriorView frame tracks interiorRect exactly
    - **Property 3: InteriorView frame tracks interiorRect exactly**
    - **Validates: Requirements 2.3, 2.8**
    - Create `Tests/HoloscapePropertyTests/ChromeInteriorRectFramePropertyTests.swift`

- [ ] 6. Checkpoint
  - Ensure new view tests pass; ensure no existing test regresses.

- [ ] 7. PR #4 — Load-time bake pipeline and SHA cache
  - [ ] 7.1 Create ChromeBakePipeline
    - Create `Sources/Holoscape/Services/ChromeBakePipeline.swift` per the design's Component 3 interface
    - `@MainActor final class ChromeBakePipeline` with `cacheRoot: URL` initialized to `FileManager.default.cachesDirectory.appendingPathComponent("holoscape-skins")` by default
    - `bake(manifest:skinDir:)` walks `manifest.surfaces` (v3 surfaces) and renders into a `CGContext` at `(width * 2, height * 2)` pixels using the existing `SkinContext.applyFill` / sprite / ninepatch logic, off the main thread, hopping back for the `CGImage` install
    - Compute SHA-256 over concatenated manifest JSON bytes + every referenced asset's bytes
    - Write cache PNG at `cacheRoot/<sha>.png`; read back on cache hit
    - Implement `purgeLRU(preservingSHAs:)` enforcing the existing 50 MB cap shared with `.wamp` cache
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

  - [ ] 7.2 Wire ChromeBakePipeline into SkinEngine
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to add `let bakePipeline: ChromeBakePipeline`
    - In `loadComposite(named:)`, when `manifest.chrome?.mode == .composed`, call `bakePipeline.bake(manifest:skinDir:)` and store the returned `(image, sha)` in `LoadedSkin`
    - When `manifest.chrome?.mode == .baked`, decode `manifest.chrome.image` directly from the skin dir (or `imageOpaque` when Reduce Transparency is active)
    - _Requirements: 5.1, 5.3, 15.1, 15.2_

  - [ ]* 7.3 Unit tests for ChromeBakePipeline
    - Create `Tests/HoloscapeTests/Unit/ChromeBakePipelineTests.swift`
    - Test cold bake produces a non-empty `CGImage`
    - Test second bake on the same inputs hits cache and skips `CGContext`
    - Test SHA determinism: two independent bakes produce identical hashes
    - Test LRU purge preserves active SHAs
    - Test cold bake completes in ≤ 500 ms for a 1000×700 logical skin
    - _Requirements: 5.1, 5.2, 5.4, 5.6, 5.7, 5.8_

  - [ ]* 7.4 Property test: SHA cache determinism
    - **Property 5: SHA cache is deterministic**
    - **Validates: Requirements 5.2, 5.3, 5.4, 5.5**
    - Create `Tests/HoloscapePropertyTests/ChromeBakeDeterminismPropertyTests.swift`
    - Generate arbitrary composed-mode manifests; assert two independent bakes produce byte-identical PNGs and SHAs

- [ ] 8. Checkpoint
  - Ensure `swift test` green; ensure `ChromeBakePipeline` can bake a fixture composed manifest end-to-end.

- [ ] 9. PR #5 — Chrome manifest validator
  - [ ] 9.1 Create ChromeManifestValidator
    - Create `Sources/Holoscape/Services/ChromeManifestValidator.swift` per the design's Component 4 interface
    - Static `validate(manifest:baseImage:windowShape:)` returns `ChromeValidationResult`
    - Compute non-zero-alpha bounding box of `baseImage`; compare to `windowShape.polygons` bounding box; compute delta in each dimension
    - Validate every `ChromeAnimationLayer.id` is unique
    - Validate every `rect` is inside `(0, 0, chrome.width, chrome.height)`
    - Validate kind-specific params: `gridRows * gridCols >= frameCount` (sprite), `birthRate > 0` (particle), `palette.count > 0` and every `defaultState` inside `[0, palette.count)` (LED), `preset in {glow, scanlines, noise}` (shader)
    - Validate referenced assets exist in the skin bundle
    - Warn (not reject) when `chrome.width < 200` or `chrome.height < 100`
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.9_

  - [ ] 9.2 Wire validator into SkinEngine
    - Modify `SkinEngine.loadComposite` to invoke `ChromeManifestValidator.validate` after bake/decode and propagate `warningReason` into `LoadedSkin.validationBannerReason`
    - Populate `LoadedSkin.chromeValidation` with the full `ChromeValidationResult`
    - _Requirements: 12.7, 12.8, 13.3_

  - [ ] 9.3 Propagate validator warnings to SkinWarningBanner
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to pass `LoadedSkin.validationBannerReason` into the existing `SkinWarningBanner.show(_:)` path
    - Disabled animation ids from `ChromeValidationResult.disabledAnimationIDs` must be skipped at install time in the PR #13 compositor wiring (note the contract here)
    - _Requirements: 12.7, 12.8_

  - [ ]* 9.4 Unit tests for ChromeManifestValidator
    - Create `Tests/HoloscapeTests/Unit/ChromeManifestValidatorTests.swift`
    - Test polygon-vs-alpha agreement at 0px, 1px, 2px (accepted), 3px (rejected) drift
    - Test duplicate animation id detection
    - Test animation rect out-of-bounds detection
    - Test every kind's param validation (valid + each invalid case)
    - Test missing asset detection
    - Test unknown shader preset rejection
    - Test sub-minimum size warning
    - Test non-RGBA chrome image rejection
    - Test `interiorRect` outside image bounds rejection
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.8, 12.9_

  - [ ]* 9.5 Property test: Polygon vs alpha agreement
    - **Property 4: Polygon vs alpha bounds agree within ±2 logical pixels**
    - **Validates: Requirements 4.1, 4.2, 12.1, 12.2**
    - Create `Tests/HoloscapePropertyTests/PolygonAlphaAgreementPropertyTests.swift`
    - Generate polygon + alpha-image pairs; assert bounding-box delta ≤ 2px for in-spec, > 2px for out-of-spec

- [ ] 10. Checkpoint
  - Ensure validator catches every documented failure mode; ensure a malformed fixture surfaces `SkinWarningBanner` with the expected reason string.

- [ ] 11. PR #6 — MainWindowController chrome-mode branch
  - [ ] 11.1 Add Chrome_Mode_Branch to applySkin with window reconstruction
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to add `applyChromeSkin(_:)` (extension method per design's Component 9)
    - When `loaded.chrome != nil`, call `reconstructAsBorderlessTransparent(size:)` — the existing titled window CANNOT be retrofitted to transparent via property flips (PR #1 isolation test proved this, see `docs/research/chrome-risk1-transparency-findings.md`). Must construct a new `ShapedBorderlessWindow`, migrate delegate + child windows (Reader Mode panel, BugReportDialog) + first responder, `orderOut` the old window, `makeKeyAndOrderFront` the new one.
    - On the inverse transition (v4 chrome → pre-v4 skin at runtime), call `reconstructAsTitled(size:)` — symmetric reason (Requirement 3.1a).
    - Tear down any pre-existing CA-mask state on the new window before installing `ChromeHostView` as the sole child of `ShapedContentView`, install `InteriorView` as a sibling pinned to `chrome.interiorRect`, and reparent every existing app-content subview (TabBarView, NSSplitView, SidebarView, SplitPaneManager, HoloscapeTerminalView, InputBoxView, SessionLauncherView) from `ShapedContentView` to `InteriorView`
    - When `loaded.chrome == nil`, route through the existing pre-v4 path (including old `applyWindowShape` CA-mask path — this is the backward-compat branch)
    - Skip `buildMaskLayer` and `WindowDragOverlay` entirely in the chrome-mode branch
    - Continue to call `HitRegionSampler.contains(point)` in `ShapedContentView.hitTest(_:)` for every incoming hit test; return nil outside the polygon, delegate to `super.hitTest` inside
    - Continue to honor `dragRegions` via the existing `DragRegionTracker` installed from `manifest.dragRegions`
    - Preserve `HitRegionSampler`, `DragRegionTracker`, `ShapedBorderlessWindow`, `isReleasedWhenClosed = false`, `SkinWarningBanner`, `.wamp` loader, sprite engine, font pipeline, bundle cache, skin picker, hot reload debouncer verbatim across this PR
    - _Requirements: 2.1, 2.3, 2.4, 4.1, 4.2, 4.3, 4.4, 16.2, 16.3, 16.7_

  - [ ] 11.2 Wire validator's disabled animation ids through to compositor
    - Plumb `LoadedSkin.chromeValidation?.disabledAnimationIDs` into `applyChromeSkin` so the compositor wiring (populated in PR #13) skips these ids
    - _Requirements: 12.7_

  - [ ]* 11.3 Unit test for chrome-mode branch
    - Create `Tests/HoloscapeTests/Unit/MainWindowControllerChromeBranchTests.swift`
    - Test `applySkin` with `chrome != nil` installs `ChromeHostView` and `InteriorView`, does not call `buildMaskLayer`, does not install `WindowDragOverlay`
    - Test `applySkin` with `chrome == nil` preserves the pre-v4 path
    - Test subview reparenting: every expected child moves from `ShapedContentView` to `InteriorView`
    - _Requirements: 2.1, 2.3, 2.4, 16.3_

  - [ ]* 11.4 Property test: Chrome mode branch skips old CA-mask path
    - **Property 12: Chrome mode branch skips old CA-mask path**
    - **Validates: Requirements 16.3, 16.6**
    - Create `Tests/HoloscapePropertyTests/ChromeModeBranchPropertyTests.swift`

- [ ] 12. Checkpoint
  - Ensure chrome-mode branch installs cleanly; ensure pre-v4 skins still route through the old path (HoloscapeSynthwave, HoloscapeClassic, AmplifyDemo all still render as before).

- [ ] 13. PR #7 — Borderless window + `.clear` + `hasShadow = false`
  - [ ] 13.1 Configure newly-constructed window for alpha transparency
    - The `NSWindow` itself MUST be constructed as `.borderless`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` from birth (PR #5 `reconstructAsBorderlessTransparent` already does this). This task covers the remaining config on the newly-constructed window.
    - Use `ShapedBorderlessWindow` subclass as the window class (carries forward verbatim from Amplify v1 — `canBecomeKey` / `canBecomeMain` overrides)
    - Ensure `contentMinSize == contentMaxSize == (chrome.width, chrome.height)` and `.resizable` NOT present in `styleMask`
    - Do NOT attempt to retrofit an existing titled window — PR #1 investigation showed AppKit locks in opaque backing at construction time (`docs/research/chrome-risk1-transparency-findings.md`).
    - _Requirements: 3.1, 3.6_

  - [ ]* 13.2 Integration test for alpha equality
    - Create a new test case in `Tests/HoloscapeTests/Integration/ChromeHotReloadIntegrationTests.swift` (will exist by this point) or a new file `Tests/HoloscapeTests/Integration/ChromeTransparencyIntegrationTests.swift` that loads a fixture with cut corners and asserts window composited alpha equals base layer alpha at a sample of pixels
    - _Requirements: 3.2, 3.3, 3.4_

  - [ ]* 13.3 Property test: Chrome alpha equality
    - **Property 2: Chrome base image alpha equals window alpha**
    - **Validates: Requirements 3.2, 3.3, 3.4**
    - Create `Tests/HoloscapePropertyTests/ChromeAlphaEqualityPropertyTests.swift`

- [ ] 14. Checkpoint
  - Ensure a chrome-mode skin renders with transparent cut corners on laptop; confirm visually.

- [ ] 15. PR #8 — Drag via background
  - [ ] 15.1 Enable isMovableByWindowBackground; remove WindowDragOverlay from chrome-mode branch
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to set `window.isMovableByWindowBackground = true` in the chrome-mode branch
    - Ensure `WindowDragOverlay` is not installed in the chrome-mode branch (`WindowDragOverlay` class stays in the tree until PR #20; only its installation site in chrome-mode is removed)
    - Continue to honor `manifest.dragRegions` via existing `DragRegionTracker`
    - _Requirements: 4.4, 4.5, 4.6_

  - [ ]* 15.2 Integration test for drag
    - Extend `Tests/HoloscapeTests/Integration/ChromeHotReloadIntegrationTests.swift` with a test that asserts `isMovableByWindowBackground == true` on a chrome-mode skin and `WindowDragOverlay` is absent from the view tree
    - _Requirements: 4.5, 4.6_

- [ ] 16. Checkpoint
  - Ensure dragging a chrome-mode window from any opaque bare-Base_Layer pixel moves the window; ensure `dragRegions`-declared strips continue to drag when declared.

- [ ] 17. PR #9 — Malformed chrome fallback + Reduce Transparency variant
  - [ ] 17.1 Implement rectangular fallback on malformed chrome
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to, when `ChromeManifestValidator` returns a fatal reason (missing image, non-RGBA, dimension mismatch, interiorRect outside), return a `LoadedSkin` with `chrome = nil` and `validationBannerReason` set
    - Modify `MainWindowController.applyChromeSkin` to, when `loaded.chrome == nil` but `loaded.validationBannerReason != nil`, render rectangular with declared v3 surface fills and surface the banner
    - _Requirements: 12.8_

  - [ ] 17.2 Implement Reduce Transparency fallback
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to, when `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == true`, prefer `chrome.imageOpaque` if declared; otherwise multiply `chrome.image` alpha to 1.0 on non-zero-alpha pixels and use the opacified variant
    - Cache both variants under a scoped sub-SHA (`<sha>.png` and `<sha>.opaque.png`) so transparency-preference toggles don't re-bake
    - _Requirements: 15.1, 15.2_

  - [ ]* 17.3 Unit tests for fallback behavior
    - Extend `Tests/HoloscapeTests/Unit/ChromeManifestValidatorTests.swift` (or create a new `ChromeFallbackTests.swift`) with fixtures exercising every fatal reason
    - Test Reduce Transparency fallback picks `imageOpaque` when declared
    - Test Reduce Transparency fallback opacifies `chrome.image` when `imageOpaque` absent
    - _Requirements: 12.8, 15.1, 15.2_

- [ ] 18. Checkpoint — End of Phase 1
  - Ensure chrome-mode branch fully works for static skins (no animations yet); ensure malformed skins fall back gracefully; ensure Reduce Transparency is honored; ensure every pre-v4 skin still renders unchanged through the legacy path.

- [ ] 19. PR #10 — Particle emitter layer
  - [ ] 19.1 Create SharedAnimationClock
    - Create `Sources/Holoscape/Services/SharedAnimationClock.swift` per the design's Component 6 interface
    - `@MainActor final class SharedAnimationClock` with a single `CADisplayLink`
    - `subscribe(_:) / unsubscribe(_:) / start() / stop() / pause() / resume()`
    - Deliver ticks to every subscribed `AnimatedLayerRenderer` per vsync frame
    - `os_signpost` instrumentation for budget measurement (category `"chrome.animation.tick"`)
    - _Requirements: 11.2, 11.3, 15.3_

  - [ ] 19.2 Create AnimatedLayerRenderer protocol and ParticleLayerRenderer
    - Create `Sources/Holoscape/Services/AnimatedLayerRenderer.swift` with the protocol per the design's Component 5 interface
    - Create `Sources/Holoscape/Services/ParticleLayerRenderer.swift` — `CAEmitterLayer`-backed; maps every `ParticleParams` field to the corresponding `CAEmitterCell` property; synthesizes a procedurally-generated soft dot when `params.image == nil`; honors `blendMode` via `compositingFilter`
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [ ] 19.3 Wire ParticleLayerRenderer into ChromeHostView
    - Modify `Sources/Holoscape/Views/ChromeHostView.swift` to instantiate one `AnimatedLayerRenderer` per `ChromeAnimationLayer` in `chrome.animations` where `kind == .particle`
    - Install each renderer's `layer` into `animatedLayersContainer` at z-ordered position
    - Subscribe each renderer to `SharedAnimationClock` (stub for other kinds, to be filled in subsequent PRs)
    - Reject particle descriptors whose declared texture allocation (image size × particle count headroom derived from `birthRate * lifetime`) would exceed 64 MB GPU memory; surface `SkinWarningBanner` and add to `disabledAnimationIDs` instead of installing
    - Apply `SingleContainerMask` so every particle clips to Chrome_Silhouette (partial — mask wiring completes in PR #13)
    - _Requirements: 6.1, 6.5, 10.3, 10.4, 11.4_

  - [ ]* 19.4 Unit tests for ParticleLayerRenderer
    - Create `Tests/HoloscapeTests/Unit/ParticleLayerRendererTests.swift`
    - Test every `ParticleParams` field maps to a `CAEmitterCell` property
    - Test procedurally-generated soft dot when image is nil
    - Test `blendMode.additive` sets `compositingFilter = "plusL"` (or equivalent)
    - _Requirements: 6.2, 6.3, 6.4_

  - [ ]* 19.5 Visual-verification integration fixture
    - Create `Tests/Fixtures/Chrome/only-particle.wamp` via a new `Tools/build_chrome_fixtures.sh` script
    - Extend `Tests/HoloscapeTests/Integration/ChromeHotReloadIntegrationTests.swift` (or a new integration test file) to load `only-particle.wamp` and verify a `CAEmitterLayer` is installed
    - _Requirements: 6.1_

- [ ] 20. Checkpoint
  - Ensure `only-particle.wamp` renders a visible particle emitter on laptop; ensure `SharedAnimationClock` ticks are delivered.

- [ ] 21. PR #11 — LED array + sprite animation layers
  - [ ] 21.1 Create LEDArrayLayerRenderer
    - Create `Sources/Holoscape/Services/LEDArrayLayerRenderer.swift` — renders one `CALayer` per cell, sized `cellSize × cellSize`, positioned at `(x, y)` in top-left coords inside `layer.rect`
    - Cell geometry + palette swatches built once at install; zero per-frame allocation
    - Implement every `Pattern` case deterministically against phase seconds: `.steady`, `.blink(hz, duty)`, `.phased(hz)`, `.random(hz, density)`, `.marquee(cellsPerSecond, windowSize)`
    - Honor `phaseOffset` and `speedMultiplier`
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 7.10_

  - [ ] 21.2 Create SpriteAnimLayerRenderer
    - Create `Sources/Holoscape/Services/SpriteAnimLayerRenderer.swift` — `CALayer` with `contents = spriteSheet`, advancing `contentsRect` UV offsets at declared `fps`
    - Respect `frameCount` (may be less than `gridRows * gridCols`)
    - Implement `loop / pingPong / once` modes
    - Honor `phaseOffset` and `speedMultiplier`
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_

  - [ ] 21.3 Wire LED + sprite renderers into ChromeHostView
    - Extend `ChromeHostView.installAnimatedLayers` to instantiate `LEDArrayLayerRenderer` for `kind == .ledArray` and `SpriteAnimLayerRenderer` for `kind == .spriteAnim`
    - Subscribe both to `SharedAnimationClock`
    - _Requirements: 7.1, 8.1, 10.3, 10.4_

  - [ ]* 21.4 Unit tests for LEDArrayLayerRenderer
    - Create `Tests/HoloscapeTests/Unit/LEDArrayLayerRendererTests.swift`
    - Test cell geometry built exactly once at install
    - Test every `Pattern` case produces the expected state at known times with known phaseOffsets
    - Test `phaseOffset` and `speedMultiplier` applied correctly
    - _Requirements: 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9, 7.10_

  - [ ]* 21.5 Unit tests for SpriteAnimLayerRenderer
    - Create `Tests/HoloscapeTests/Unit/SpriteAnimLayerRendererTests.swift`
    - Test `contentsRect` advances through `frameCount` at declared `fps`
    - Test `loop / pingPong / once` behaviors at end of sequence
    - Test `frameCount < gridRows * gridCols` handled
    - _Requirements: 8.2, 8.3, 8.4, 8.5, 8.6_

  - [ ]* 21.6 Property test: Animation phase determinism
    - **Property 9: Phase offset + speed multiplier produce deterministic layer state**
    - **Validates: Requirements 7.10, 8.7**
    - Create `Tests/HoloscapePropertyTests/AnimationPhaseDeterminismPropertyTests.swift`

  - [ ]* 21.7 Visual-verification integration fixtures
    - Create `Tests/Fixtures/Chrome/only-led.wamp` and `Tests/Fixtures/Chrome/only-sprite.wamp` via the fixture build script
    - Extend integration tests to load each and verify layers are installed

- [ ] 22. Checkpoint
  - Ensure `only-led.wamp` and `only-sprite.wamp` render correctly on laptop; ensure `SharedAnimationClock` ticks both in phase.

- [ ] 23. PR #12 — Shader preset layer
  - [ ] 23.1 Ship glow / scanlines / noise as built-in Metal shaders
    - Create `Sources/Holoscape/Shaders/ChromeShaders.metal` with three functions: `glow_fragment`, `scanlines_fragment`, `noise_fragment`
    - Each fragment shader takes a uniform buffer matching `ShaderParams` (color, intensity, hz, plus time)
    - Modify `Package.swift` to include `.metal` source compilation at app build time (if not already enabled)
    - _Requirements: 9.2_

  - [ ] 23.2 Create ShaderPresetLayerRenderer
    - Create `Sources/Holoscape/Services/ShaderPresetLayerRenderer.swift` — `CAMetalLayer`-backed; sets `isOpaque = false`, `framebufferOnly = false`
    - Look up shader function by preset name via `MTLLibrary.makeFunction`
    - Allocate uniform buffer from `ShaderParams`; update per tick
    - _Requirements: 9.1, 9.2, 9.3, 9.5_

  - [ ] 23.3 Handle unknown preset gracefully
    - In `ShaderPresetLayerRenderer.init`, when the shader function is missing from the compiled library, return nil
    - `ChromeHostView.installAnimatedLayers` skips nil renderers
    - `ChromeManifestValidator` already rejects unknown presets at load time; this is defense in depth
    - _Requirements: 9.4_

  - [ ] 23.4 Wire shader renderer into ChromeHostView
    - Extend `ChromeHostView.installAnimatedLayers` to instantiate `ShaderPresetLayerRenderer` for `kind == .shader`
    - Subscribe to `SharedAnimationClock`
    - _Requirements: 9.1, 10.3, 10.4_

  - [ ]* 23.5 Unit tests for ShaderPresetLayerRenderer
    - Create `Tests/HoloscapeTests/Unit/ShaderPresetLayerRendererTests.swift`
    - Test each preset's uniform buffer layout matches the shader's expected schema
    - Test unknown preset returns nil
    - Test `CAMetalLayer.isOpaque = false` and `framebufferOnly = false`
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [ ]* 23.6 Visual-verification integration fixture
    - Create `Tests/Fixtures/Chrome/only-shader.wamp` with a glow preset
    - Extend integration tests to load and verify

- [ ] 24. Checkpoint
  - Ensure `only-shader.wamp` renders glow on laptop; ensure scanlines and noise presets also render via per-preset fixtures or manual verification.

- [ ] 25. PR #13 — Animation clipping + density/Reduce Motion
  - [ ] 25.1 Install Single_Container_Mask on animated-layer container
    - Modify `Sources/Holoscape/Views/ChromeHostView.swift` to derive a `CAShapeLayer` mask from `baseLayer`'s non-zero-alpha pixels and install it as `animatedLayersContainer.mask`
    - Rebuild the mask on `updateBaseImage(_:)` (hot reload of chrome image)
    - Enforce z-order invariant: Base_Layer implicit `z = 0`, every animated layer must have `z > 0` or it is rejected by `ChromeManifestValidator` (extension to task 9.1 validation); assert invariant at install time in `ChromeHostView`
    - Order siblings sharing the same `z` by their position in `chrome.animations` (earlier in the array renders first)
    - On older hardware (pre-M1) where frame time exceeds 16.6 ms, allow Core Animation to drop frames rather than blocking the main thread; `SharedAnimationClock` does not manually skip ticks
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 11.5_

  - [ ] 25.2 Implement density mode transitions
    - Modify `ChromeHostView.setDensityMode(_:)` to: `.off` → tear down every renderer's layer and unsubscribe from clock (zero cost); `.minimal` → call `clock.pause()` and keep every layer visible at current frame; `.full` → re-install layers if previously `.off`, `clock.start()` + `clock.resume()`
    - Preserve renderer state across `.full` → `.minimal` transitions so the frame holds
    - Restart from declared `phaseOffset` on `.off` → `.full`
    - _Requirements: 15.4, 15.5, 15.6, 15.7, 15.8, 15.9_

  - [ ] 25.3 Implement Reduce Motion freeze
    - Modify `ChromeHostView.freezeForReduceMotion()` to call `clock.pause()` while keeping every layer in the tree
    - Modify `ChromeHostView.resumeFromReduceMotion()` to call `clock.resume()`
    - Observe `NSWorkspace.shared` accessibility notifications for runtime toggling
    - _Requirements: 15.3_

  - [ ] 25.4 Mark animated layers as accessibility-hidden
    - Ensure every `AnimatedLayerRenderer` marks its layer with `accessibilityElementIsHidden = true` (or equivalent) so VoiceOver skips them
    - _Requirements: 15.10_

  - [ ]* 25.5 Property test: Animated layer clip invariant
    - **Property 7: No animated layer renders a pixel where chrome alpha == 0**
    - **Validates: Requirements 10.1, 10.2, 15.4**
    - Create `Tests/HoloscapePropertyTests/AnimatedLayerClipPropertyTests.swift`
    - Generate arbitrary descriptors whose `rect` extends past the alpha silhouette; rasterize a frame; assert zero pixels outside silhouette

  - [ ]* 25.6 Property test: Reduce Motion freezes but does not hide
    - **Property 10: Reduce Motion freezes but does not hide**
    - **Validates: Requirements 15.3**
    - Create `Tests/HoloscapePropertyTests/ReduceMotionFreezePropertyTests.swift`

  - [ ]* 25.7 Property test: Density mode transitions preserve visible state
    - **Property 11: Density mode transitions preserve visible state correctly**
    - **Validates: Requirements 15.4, 15.5, 15.6, 15.7, 15.8, 15.9**
    - Create `Tests/HoloscapePropertyTests/DensityModeTransitionPropertyTests.swift`

- [ ] 26. Checkpoint — End of Phase 2
  - Ensure every animation kind clips to the chrome silhouette; ensure Reduce Motion freezes; ensure density mode transitions work cleanly; ensure `os_signpost` traces show ≤ 8ms per frame on laptop.

- [ ] 27. PR #14 — HoloscapeClassic-live reference skin
  - [ ] 27.1 Author HoloscapeClassic-live with all four animation kinds
    - Create `Sources/Holoscape/Resources/Skins/HoloscapeClassic-live/` alongside existing `HoloscapeClassic/`
    - Author `skin.json` with `chrome.mode: .composed` (reusing existing HoloscapeClassic surfaces), `chrome.interiorRect`, and `chrome.animations` containing: one particle emitter (sparks in a porthole region), one LED array (status ladder above the tab bar), one sprite animation (scrolling LCD marquee in the top band), one shader preset (soft glow behind a glass panel)
    - Generate sprite sheets + particle image via `Tools/holoscape_classic_live/generate_assets.py` (Pillow, following the pattern set by `Tools/holoscape_classic/generate_sprites.py`)
    - Package with `Tools/package_holoscape_classic_live.sh` → `HoloscapeClassic-live.wamp`
    - Ship both directory-layout and `.wamp` per project convention
    - _Requirements: 1.1, 1.3, 6.1, 7.1, 8.1, 9.1_

  - [ ] 27.2 Record a 5-second screen capture of HoloscapeClassic-live
    - Capture on the Mac Mini via `xcrun simctl io` or QuickTime Player
    - Save to `docs/reference/holoscape-classic-live-demo.mov` (or `.gif` for size)
    - Linked from PROGRESS.md after PR #14 merges
    - _Requirements: ties to PRD Success Metric "Chrome moves"_

  - [ ]* 27.3 Integration test for HoloscapeClassic-live
    - Extend `Tests/HoloscapeTests/Integration/BackwardCompatIntegrationTests.swift` with a `HoloscapeClassic-live` scenario that asserts the skin loads and every animation kind installs
    - _Requirements: 16.5_

- [ ] 28. Checkpoint
  - Mac Mini dogfood of HoloscapeClassic-live; Erik's "cooler than Winamp" sign-off (PRD Success Metric).

- [ ] 29. PR #15 — HoloscapeSynthwave migration to v4 composed
  - [ ] 29.1 Migrate HoloscapeSynthwave to composed mode with ambient animations
    - Modify `Sources/Holoscape/Resources/Skins/HoloscapeSynthwave/skin.json` to add `chrome.mode: .composed`, `chrome.interiorRect`, and `chrome.animations` with a subtle ambient particle emitter + scanlines shader
    - Re-package `HoloscapeSynthwave.wamp` via `Tools/package_synthwave.sh`
    - Ensure existing v3 surface descriptors continue to paint as before inside InteriorView
    - _Requirements: 1.3, 16.1_

  - [ ]* 29.2 Backward-compat test
    - Extend `BackwardCompatIntegrationTests.swift` to assert v3 HoloscapeSynthwave renders identically to v4 HoloscapeSynthwave (modulo the new animations, which are additive and can be asserted separately)
    - _Requirements: 16.1, 16.5_

- [ ] 30. Checkpoint
  - Ensure HoloscapeSynthwave renders unchanged visually (plus new ambient animations); ensure v3 test lane still passes.

- [ ] 31. PR #16 — AmplifyDemo migration to v4 composed
  - [ ] 31.1 Migrate AmplifyDemo to composed mode with glow shader
    - Modify `Sources/Holoscape/Resources/Skins/AmplifyDemo/skin.json` to add `chrome.mode: .composed`, `chrome.interiorRect`, and `chrome.animations` with a single glow shader preset (minimal-animations case)
    - Re-package `AmplifyDemo.wamp` if one exists; otherwise ship directory-layout only
    - _Requirements: 1.3, 16.1_

  - [ ]* 31.2 Backward-compat test
    - Extend `BackwardCompatIntegrationTests.swift` to cover AmplifyDemo v4
    - _Requirements: 16.5_

- [ ] 32. Checkpoint
  - Ensure AmplifyDemo renders correctly with glow shader; ensure v3 test lane still passes.

- [ ] 33. PR #17 — Docs + template
  - [ ] 33.1 Write docs/chrome-format.md
    - Create `docs/chrome-format.md` covering: ChromeDescriptor fields, authoring modes, every animated-layer kind with its params, decision table ("marquee → spriteAnim or LED marquee; drifting sparks → particle; pulsing glow → shader preset glow"), worked recipes for HoloscapeClassic-live's four animations, validator error messages, density mode interaction, Reduce Motion behavior
    - _Requirements: ties to PRD §10 UX / Authoring Flow_

  - [ ] 33.2 Ship chrome template assets
    - Create `docs/chrome-template.png` — a 1000×700 RGBA PNG with the interior rect drawn as a semitransparent colored rectangle and cut corners outlined
    - Create `docs/chrome-template.psd` (Photoshop layered version)
    - Reference both from `docs/chrome-format.md`
    - _Requirements: ties to PRD Success Metric "Time to author (baked mode, static) ≤ 30 min"_

- [ ] 34. Checkpoint — End of Phase 3
  - Ensure docs + template assets ship; ensure HoloscapeClassic-live, HoloscapeSynthwave, AmplifyDemo all render on Mac Mini with animations verified live.

- [ ] 35. PR #18 — Integration tests (backward-compat extension)
  - [ ] 35.1 Extend BackwardCompatIntegrationTests with six new scenarios
    - Modify `Tests/HoloscapeTests/Integration/BackwardCompatIntegrationTests.swift` to add: v4 composed directory (no anim), v4 composed `.wamp` (no anim), v4 baked directory (no anim), v4 baked `.wamp` (no anim), v4 composed with every MVP animation kind, v4 baked with every MVP animation kind
    - For each lane, assert: load succeeds, `LoadedSkin` has expected `chrome` shape, renders without throwing, animation layer count matches descriptor count
    - _Requirements: 16.4, 16.5_

  - [ ] 35.2 Extend hot-reload integration tests
    - Create or extend `Tests/HoloscapeTests/Integration/ChromeHotReloadIntegrationTests.swift` with tests that: edit the chrome base image on disk and assert swap within 200 ms; edit a `chrome.animations` entry and assert the diff-by-id swaps params in place; with Reduce Motion enabled, assert skin swaps complete instantly without crossfade
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6_

  - [ ]* 35.3 Property test: Backward-compat matrix across all lanes
    - **Property 6: Backward compatibility matrix holds across six lanes**
    - **Validates: Requirements 16.1, 16.2, 16.3, 16.4, 16.5**
    - Create `Tests/HoloscapePropertyTests/ChromeBackwardCompatPropertyTests.swift`

- [ ] 36. Checkpoint
  - Ensure every new backward-compat lane is green; ensure hot reload works for all v4 scenarios.

- [ ] 37. PR #19 — Debug overlay + Mac Mini UI tests
  - [ ] 37.1 Implement ChromeDebugOverlay
    - Create `Sources/Holoscape/Views/ChromeDebugOverlay.swift` per the design's Component 7 interface
    - Render semitransparent false-color alpha of Base_Layer, red outline of interiorRect, green outlines of windowShape polygons, yellow outline + id label for every animated layer, live phase clock readout
    - Install when `HOLOSCAPE_PNG_CHROME_DEBUG=1`; subscribe to `SharedAnimationClock` for per-frame refresh
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7_

  - [ ] 37.2 Mac Mini UI test for live transparency
    - Create `Tests/HoloscapeTests/Integration/ChromeTransparencyUITests.swift` — XCUITest that launches Holoscape with HoloscapeClassic-live over a known-bright backdrop and screenshot-samples a cut-corner pixel, asserting backdrop color visible
    - Runs on Mac Mini only (per per-project convention — XCUITests don't run on laptop)
    - _Requirements: 3.5, ties to PRD §17.8_

  - [ ] 37.3 Mac Mini UI test for animation smoke
    - Create `Tests/HoloscapeTests/Integration/ChromeAnimationSmokeUITests.swift` — records a 5-second capture of HoloscapeClassic-live, programmatically samples frames to assert particle / LED / marquee / glow all visible
    - Mac Mini only
    - _Requirements: 6.1, 7.1, 8.1, 9.1_

  - [ ]* 37.4 Property test: Animation frame budget
    - **Property 8: Animated layer frame budget held**
    - **Validates: Requirements 11.1, 11.2, 11.3**
    - Create `Tests/HoloscapePropertyTests/AnimationFrameBudgetPropertyTests.swift`
    - Marked as flaky-tolerated; samples `os_signpost` durations

- [ ] 38. Checkpoint
  - Ensure Mac Mini UI tests pass; ensure debug overlay renders correctly; ensure `os_signpost` traces show ≤ 8ms per frame for HoloscapeClassic-live.

- [ ] 39. PR #20 — Delete old mask path
  - [ ] 39.1 Delete ShapedWindowController.buildMaskLayer and related CA-mask code
    - Modify `Sources/Holoscape/Controllers/ShapedWindowController.swift` to remove `buildMaskLayer(for:in:)` entirely
    - Move concave-interior masking to `InteriorView.layer.mask` (already in place from task 5.2); no re-install needed at the `ShapedContentView` level
    - _Requirements: 16.6_

  - [ ] 39.2 Delete WindowDragOverlay
    - Delete `WindowDragOverlay` class from `Sources/Holoscape/Views/ShapedContentView.swift` (class + all references)
    - All chrome-mode skins rely on `isMovableByWindowBackground = true`; any pre-v4 skin that still needed `WindowDragOverlay` must have migrated to v4 by PR #20 or be explicitly deferred (and a spec amendment filed)
    - _Requirements: 4.6, 16.6_

  - [ ] 39.3 Delete polygon scaling + windowDidResizeForShape
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to delete the polygon scaling helpers and the `windowDidResizeForShape` observer
    - v4 chrome is fixed-size by construction (Requirement 3.6); no resize handling needed
    - _Requirements: 3.6, 16.6_

  - [ ] 39.4 Delete writeShapeDiagnostic infrastructure
    - Search for any remaining `writeShapeDiagnostic` references across `Sources/Holoscape/**` and delete them
    - Delete the `/tmp/holoscape-shape-diag.log` file-writing code paths
    - _Requirements: 16.6_

  - [ ] 39.5 Delete the pre-v4 HoloscapeClassic skin directory
    - Delete `Sources/Holoscape/Resources/Skins/HoloscapeClassic/` in its entirety — the v3 skin is superseded by `HoloscapeClassic-live` (shipped in PR #14) and uses the old `CALayer.mask` path being removed in this PR
    - Update any in-tree references (skin picker default list, test fixtures, docs) that still name `HoloscapeClassic` to name `HoloscapeClassic-live` instead
    - Remove any `HoloscapeClassic`-named `.wamp` artifacts from `Sources/Holoscape/Resources/Skins/` and `Tools/`
    - _Requirements: 16.6_

  - [ ] 39.6 Verify every in-tree shaped skin has migrated to v4
    - Before merging PR #20, confirm: HoloscapeSynthwave (PR #15), HoloscapeClassic-live (PR #14 — replacing the now-deleted pre-v4 HoloscapeClassic per 39.5), AmplifyDemo (PR #16) all ship v4 `chrome` descriptors and render via Chrome_Mode_Branch; `BackwardCompatIntegrationTests` green on all ten lanes
    - Document the confirmation in the PR description
    - _Requirements: 16.6_

  - [ ]* 39.7 Regression test for chrome-mode-only rendering path
    - Extend `Tests/HoloscapeTests/Unit/MainWindowControllerChromeBranchTests.swift` to assert that after PR #20, `MainWindowController` no longer has any call site for `buildMaskLayer`, `WindowDragOverlay`, polygon scaling, or `writeShapeDiagnostic`
    - _Requirements: 16.6_

- [ ] 40. Final checkpoint
  - Run full test suite: `swift test` green; `swift build -c release` green; `./bundle.sh` produces a valid `.app`
  - Mac Mini dogfood: switch between Default, HoloscapeSynthwave, HoloscapeClassic-live, AmplifyDemo; verify no hot-reload glitches, no frame drops, animations in phase, transparency at cut corners, click-through outside silhouette, drag inside silhouette
  - Verify `os_signpost` traces over a 30-second HoloscapeClassic-live session show compositor commit ≤ 8 ms per frame for 99%+ of frames (M1 laptop)
  - Verify backward-compat: every scenario in `BackwardCompatIntegrationTests` green across all ten lanes (v2 dir, v2 wamp, v3 dir, v3 wamp, v4 composed dir no-anim, v4 composed wamp no-anim, v4 baked dir no-anim, v4 baked wamp no-anim, v4 composed with all anim kinds, v4 baked with all anim kinds)
  - Verify performance budgets: cold bake ≤ 500 ms for 1000×700 @2x; warm cache hit ≤ 30 ms; hit-test sampling ≤ 100 µs per point for 64-vertex polygons; hot-reload debounce honored at 200 ms
  - _Requirements: 3.5, 5.7, 5.8, 11.1, 11.2, 11.3, 13.2, 16.4, 16.5, 16.6_

## Notes

- Tasks marked with `*` are optional property-based and integration tests; they can be skipped for a faster MVP but every correctness property from design.md has a corresponding optional task for eventual coverage. Task 1.2 is NOT optional — it is the gate on the entire plan.
- Every task references specific requirements via `_Requirements: X.Y_` tags for traceability.
- Checkpoints (Tasks 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40) ensure incremental validation and map 1-to-1 with the 20 PRs in PRD §12.
- Phase transitions are explicit: Phase 1 ends at Task 18; Phase 2 ends at Task 26; Phase 3 ends at Task 34; Phase 4 ends at Task 40.
- Old-path deletion is the final PR and requires every in-tree shaped skin to have migrated to v4 with animations verified live, AND the pre-v4 HoloscapeClassic directory to have been deleted (Tasks 39.5 + 39.6 gating checks).
- Fixtures for each animation kind live under `Tests/Fixtures/Chrome/` and are built by `Tools/build_chrome_fixtures.sh`.
- **Property-test iteration counts.** SwiftCheck property tests default to 100 iterations per test. Tests that touch disk (bake pipeline, cache operations, `.wamp` extraction) drop to 25 iterations to keep wall-clock runtime bounded. UI / Mac Mini tests run once per invocation — they are scenario tests, not property tests. These conventions hold across every `- [ ]*` property-test task in this plan unless the task body states otherwise.
