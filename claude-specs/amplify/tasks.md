# Implementation Plan: Amplify — Winamp-class Chrome Skinning

> **Reconciled 2026-04-19** against `.kiro/specs/amplify-skinning/tasks.md`. Task 7 no longer creates `AlphaHitSampler` (mask shapes are post-MVP); Task 11 uses `layer.contentsRect` UV offsets instead of sub-image slicing; Task 13 restates font process-scope as a hard invariant. Requirement references renumbered to match the reconciled requirements.md.

## Overview

This plan breaks Amplify into 11 task groups that land in the PR sequence proposed by the PRD §12: data model additions → `.wamp` loader (prerequisite for any skin-as-bundle work) → shaped windows → click-through hit testing → drag regions → sprite sheets → font consumption → border/corner/shadow consumption → reader panel skinning → reference skin (`HoloscapeClassic`) + `HoloscapeSynthwave` repackage → docs. Tasks follow the project's Swift/AppKit conventions: `Codable, Equatable, Sendable` models; `@MainActor final class` services; property tests via SwiftCheck under `Tests/HoloscapePropertyTests/` (flat layout); unit + integration tests via XCTest under `Tests/HoloscapeTests/{Unit,Integration}/`. The Amplify additions are strictly additive to the chrome-skinning architecture — no existing test or file is deleted, only extended.

Checkpoints validate incremental progress against the existing `HoloscapeSynthwave` reference skin's backward-compat contract (every Amplify-format PR must continue to render `HoloscapeSynthwave` unchanged).

## Tasks

- [x] 1. Data model additions
  - [x] 1.1 Create Amplify descriptor types
    - Create `Sources/Holoscape/Models/AmplifyDescriptors.swift` with `WindowShapeDescriptor`, `Polygon`, `Point`, `DragRegionDescriptor`, `SpriteDescriptor`, `SpriteCell`
    - All types `Codable, Equatable, Sendable`
    - `WindowShapeDescriptor.Kind` enum: `polygons`, `mask` (MVP rejects `.mask` at validate time per Requirement 2.9 — the enum case stays so v3 manifests decode, reserved for the Phase-2 mask-image path)
    - `Polygon.isValid()` returns `points.count >= 3`
    - `SpriteDescriptor.isValid(imageSize:)` guards cell dimensions against image bounds
    - _Requirements: 2.1, 2.2, 4.1, 5.1, 5.4_

  - [x] 1.2 Extend `SkinDefinition` with Amplify fields
    - Modify `Sources/Holoscape/Models/SkinDefinition.swift` to add optional `windowShape: WindowShapeDescriptor?` and `dragRegions: [DragRegionDescriptor]?` fields
    - Keep all v1 and v2 fields unchanged; v3 is additive
    - Document in the struct comment that `version: "3.0"` signals Amplify
    - _Requirements: 9.1, 9.2, 9.6_

  - [x] 1.3 Extend `FillDescriptor.image` with optional sprite metadata
    - Modify `Sources/Holoscape/Models/SurfaceDescriptor.swift` `FillDescriptor.image` case to carry `sprite: SpriteDescriptor?` as a third associated value
    - Update `FillDescriptor` Codable `init(from:)` to `decodeIfPresent` sprite on the image branch; encode with `encodeIfPresent`
    - v2 manifests omitting `sprite` decode with `sprite: nil` (backward compat)
    - _Requirements: 5.1, 9.1, 9.4_

  - [x] 1.4 Extend `SurfaceKey` enum with 13 new cases
    - Modify `Sources/Holoscape/Models/SurfaceKey.swift` to add: `tabBarTabHover`, `tabBarTabPressed`, `sidebarRowPressed`, `sessionLauncherButtonNormal`, `sessionLauncherButtonHover`, `sessionLauncherButtonPressed`, `readerPanelTitleBar`, `readerPanelBackground`, `readerPanelCloseButtonNormal`, `readerPanelCloseButtonHover`, `readerPanelCloseButtonPressed`, `windowShape`, `windowDragHandle`
    - Preserve existing 23 cases and their raw values
    - _Requirements: 4.1, 5.5, 7.4, 8.1, 8.2, 8.5_

  - [x] 1.5 Extend `ReactiveUniformSnapshot` with spriteState
    - Modify `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift` to add `spriteState: Int32` field
    - Update `intValue(forMatchKey:)` to route `"spriteState"` to the new field
    - SpriteState rawValue mapping: `0=normal, 1=hover, 2=pressed, 3=active, 4=disabled, 5=focused, 6=selected`
    - _Requirements: 5.2, 5.5_

  - [x] 1.6 Define `SpriteState` enum
    - Add `SpriteState` enum to `Sources/Holoscape/Models/AmplifyDescriptors.swift` with cases `normal, hover, pressed, active, disabled, focused, selected`
    - Conform to `String, Codable, Sendable`; raw values match PRD stateMap keys
    - Add static `fromInt32(_: Int32) -> SpriteState` for snapshot → enum conversion
    - _Requirements: 5.5, 5.6_

  - [x]* 1.7 Unit tests for descriptor Codable round-trips
    - Create `Tests/HoloscapeTests/Unit/AmplifyDescriptorTests.swift`
    - Test `WindowShapeDescriptor` round-trips both `polygons` and `mask` kinds
    - Test `DragRegionDescriptor` decodes with and without `modifier`
    - Test `SpriteDescriptor` round-trips with full `stateMap`
    - Test v2 manifest (no Amplify fields) decodes with nil Amplify fields
    - Test v3 manifest decodes every Amplify field
    - _Requirements: 1.1, 9.1, 9.2_

  - [x]* 1.8 Unit tests for expanded SurfaceKey
    - Folded into the existing `Tests/HoloscapeTests/Unit/SurfaceKeyTests.swift` rather than shipping a separate `SurfaceKeyAmplifyTests.swift` file — that original split (v2 vs v3 test files) wasn't load-bearing, and keeping the SurfaceKey tests in one place means a future 37th case gets caught by the same count assertion without needing to choose between files.
    - Asserts: 13 new cases present, total case count = 36 (23 v2 + 13 v3), every raw value unique and non-empty, every v3 raw value round-trips through `SurfaceKey(rawValue:)` so typos are caught here rather than at skin-author time.
    - _Requirements: 1.4_

  - [x]* 1.9 Property test: V2 manifests decode unchanged
    - **Property 1: V2 manifest is decoded identically with or without Amplify-only fields**
    - **Validates: Requirements 9.1, 9.4, 9.5**
    - Create `Tests/HoloscapePropertyTests/AmplifyV2CompatibilityPropertyTests.swift`
    - Generate arbitrary v2 manifests via SwiftCheck; decode through Amplify `Codable`; assert byte-identical to v2-era decode

- [ ] 2. Checkpoint
  - Ensure `swift test` and `swift build` both succeed; ensure the existing `HoloscapeSynthwave` skin still loads and renders via `SkinEngineLoadCompositeTests`.

- [ ] 3. `.wamp` bundle loader
  - [ ] 3.1 Add `ZIPFoundation` dependency
    - Modify `Package.swift` to add `https://github.com/weichsel/ZIPFoundation.git` at version 0.9 or later
    - Add `ZIPFoundation` to the `Holoscape` target dependencies
    - _Requirements: 1.2, 1.6_

  - [ ] 3.2 Create `WampBundleLoader`
    - Create `Sources/Holoscape/Services/WampBundleLoader.swift` with `@MainActor final class WampBundleLoader`
    - Implement `unzipIfNeeded(bundleURL:) throws -> URL` that computes SHA-256 of bundle bytes, checks `Cache_Root/<hash>/`, unzips on miss
    - Implement `contentHash(_:) throws -> String` returning hex-encoded SHA-256
    - Implement `purgeLRU(preserving:) throws` enforcing 50 MB total cap
    - Define `WampBundleLoader.LoadError` enum: `ioFailure, notAZip, zipEntryEscapesSandbox, assetTooLarge, bundleTooLarge, missingManifest`
    - _Requirements: 1.2, 1.4, 1.5, 1.6, 1.8_

  - [ ] 3.3 Apply zip sandbox during unzip
    - In `WampBundleLoader.unzipIfNeeded`, before writing each entry, invoke `SkinEngine.validateAssetPath(_:)` on the entry path
    - After writing, invoke `SkinEngine.assertPathResolvesInside(_:root:)` on the extracted file URL with the cache subdirectory as root
    - Throw `zipEntryEscapesSandbox` with the offending path on violation
    - _Requirements: 1.3, 12.1, 12.3, 12.5_

  - [ ] 3.4 Enforce size caps
    - In `WampBundleLoader.unzipIfNeeded`, maintain a running total of uncompressed bytes written
    - Throw `assetTooLarge(path:bytes:)` if any single entry's uncompressed size exceeds 50 * 1024 * 1024
    - Throw `bundleTooLarge(bytes:)` if the running total would exceed 50 * 1024 * 1024
    - On throw, run `try? FileManager.default.removeItem(at: cacheSubdir)` to clean up the partial extraction
    - _Requirements: 1.4, 12.2_

  - [ ] 3.5 Implement LRU cache purge
    - In `WampBundleLoader.purgeLRU(preserving:)`, enumerate `Cache_Root` subdirectories sorted by `contentModificationDate` ascending
    - Compute total size by walking each subdirectory
    - Remove oldest subdirectories (except `preserving`) until total size is at or below 50 MB
    - Call from `SkinEngine.init` (startup cache cleanup)
    - _Requirements: 1.8_

  - [ ] 3.6 Extend `SkinEngine` with `.wamp` branch
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to add `let wampLoader: WampBundleLoader` field initialized in `init()` with the Holoscape-scoped cache URL
    - Extend `availableSkins()` to enumerate `.wamp` files alongside directory-layout skins; strip `.wamp` for display names; dedup with user dir winning
    - Extend `resolveSkinDir(named:)` to check `<name>.wamp` first and, when found, delegate to `wampLoader.unzipIfNeeded(bundleURL:)` before returning the unzipped directory URL
    - Extend `startWatching(skinName:)` to watch the `.wamp` file's parent directory and filter events to the bundle path when the active skin is a `.wamp`
    - _Requirements: 1.1, 1.6, 1.7, 10.1, 10.2, 10.3, 10.4_

  - [ ]* 3.7 Unit tests for WampBundleLoader
    - Create `Tests/HoloscapeTests/Unit/WampBundleLoaderTests.swift`
    - Test round-trip of fixture bundle into temp cache; verify hash-keyed path exists
    - Test second `unzipIfNeeded` on same bundle hits cache (no I/O)
    - Test sandbox rejection for `..` entry, absolute path entry, and symlink entry
    - Test size-cap rejection with `oversize.wamp` fixture
    - Test LRU purge preserves active skin subdirectory
    - _Requirements: 1.2, 1.3, 1.4, 1.8_

  - [ ]* 3.8 Property test: Zip sandbox rejects every path-traversal attack
    - **Property 2: Zip sandbox rejects every path-traversal attack**
    - **Validates: Requirements 1.3, 12.1, 12.3**
    - Create `Tests/HoloscapePropertyTests/ZipSandboxPropertyTests.swift`
    - Generate arbitrary ZIP entry paths (traversal, absolute, URL-prefixed); assert `unzipIfNeeded` throws before any write

  - [ ]* 3.9 Property test: Bundle size cap
    - **Property 3: Bundle size cap is enforced**
    - **Validates: Requirements 1.4, 12.2**
    - Add test cases to `Tests/HoloscapePropertyTests/ZipSandboxPropertyTests.swift`

  - [ ]* 3.10 Property test: SHA-256 cache key determinism
    - **Property 9: SHA-256 cache key determinism**
    - **Validates: Requirements 1.2, 10.3, 10.4**
    - Create `Tests/HoloscapePropertyTests/WampCacheKeyPropertyTests.swift`

  - [ ]* 3.11 Property test: LRU purge preserves active skin
    - **Property 14: LRU cache purge preserves active skin**
    - **Validates: Requirements 1.8**
    - Create `Tests/HoloscapePropertyTests/LRUPurgePropertyTests.swift`

- [ ] 4. Checkpoint
  - Ensure `swift test` passes with `.wamp` loader; stage `holoscape_synthwave.wamp` fixture and verify it loads via `SkinEngine.loadComposite`; verify backward-compat — `HoloscapeSynthwave` directory-layout still loads identically.

- [ ] 5. Shaped window rendering
  - [ ] 5.1 Create `ShapedWindowController`
    - Create `Sources/Holoscape/Controllers/ShapedWindowController.swift` with `@MainActor final class ShapedWindowController`
    - Store `featureFlagEnabled: Bool` computed from `ProcessInfo.processInfo.environment["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS"] == "1"`
    - Implement `buildMaskLayer(for:in:) -> CALayer?` that constructs a `CAShapeLayer` from the polygon union (MVP ships polygons only; mask-image is post-MVP per Requirement 2.9)
    - Implement `reconstructWindow(currentWindow:contentView:targetShape:) -> NSWindow` that builds a new `NSWindow` with appropriate style mask, transfers content view, preserves frame, restores key-window and first-responder
    - Implement static `validate(_:against:) -> ResolvedWindowShape?` applying Requirement 2.4 bounds check AND rejecting `WindowShapeDescriptor.kind == .mask` with the log line `"kind: mask is post-MVP; ignoring shape"` (Requirement 2.9)
    - Define `ResolvedWindowShape` struct with `kind: Kind` enum containing only `polygons([Polygon])` in MVP; leave the enum shape in place so Phase 2 can add `.mask(NSImage)` without source churn
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.8, 2.9_

  - [ ] 5.2 Wire shape application into `SkinEngine.loadComposite`
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` `loadComposite(named:)` to validate `manifest.windowShape` via `ShapedWindowController.validate` when the feature flag is on
    - Attach `ResolvedWindowShape?` to the returned `LoadedSkin` struct (add a new field)
    - On validation failure, log and return `LoadedSkin` with `windowShape: nil` plus a `validationBannerReason: String?` field
    - _Requirements: 2.4, 2.9, 13.2_

  - [ ] 5.3 Wire shape application into `MainWindowController.applySkin`
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` to add `shapedWindowController: ShapedWindowController` property initialized in `init`
    - Extend `applySkin(_:)` to, after applying surfaces, ask `shapedWindowController` whether a reconstruction is needed (flag on + non-nil shape OR flag on + transitioning from shape to rectangular)
    - If reconstruction is needed, invoke `shapedWindowController.reconstructWindow(...)` and swap the window reference; on nil shape, install no mask; on non-nil shape, install `buildMaskLayer(...)` on `contentView.layer.mask`
    - Preserve window frame, key-window status, first-responder
    - _Requirements: 2.1, 2.2, 2.3, 11.4_

  - [ ] 5.4 Apply Reduce Motion / Reduce Transparency overrides
    - In `MainWindowController.applySkin`, check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` before any fade `NSAnimationContext` block; omit the fade when true
    - In `ShapedWindowController.buildMaskLayer`, when `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true, render masked-out regions as opaque `NSColor.systemGray` instead of transparent
    - _Requirements: 2.6, 2.7, 15.1, 15.2_

  - [ ]* 5.5 Unit tests for ShapedWindowController
    - Create `Tests/HoloscapeTests/Unit/ShapedWindowControllerTests.swift`
    - Test polygon validation rejects out-of-bounds polygons
    - Test `CAShapeLayer` mask construction for `kind: polygons`
    - Test `kind: mask` is rejected with the post-MVP log line (Requirement 2.9) and `validate` returns nil
    - Test feature flag gating: flag off → `validate` returns nil regardless of input
    - _Requirements: 2.4, 2.8, 2.9_

  - [ ]* 5.6 Integration test for shape transition
    - Create `Tests/HoloscapeTests/Integration/ShapedWindowTransitionTests.swift`
    - Test rectangular → shaped → rectangular sequence; assert frame preserved and first responder preserved across swaps
    - Test no leaked `NSTrackingArea` after rectangular restoration
    - _Requirements: 2.3, 11.4_

  - [ ]* 5.7 Property test: Shape validation rejects out-of-bounds polygons
    - **Property 4: Shape validation rejects out-of-bounds polygons**
    - **Validates: Requirements 2.4, 12.7**
    - Create `Tests/HoloscapePropertyTests/ShapeValidationPropertyTests.swift`

  - [ ]* 5.8 Property test: Feature flag off disables every shape code path
    - **Property 12: Feature-flag-off disables every shape code path**
    - **Validates: Requirements 2.8**
    - Create `Tests/HoloscapePropertyTests/FeatureFlagPropertyTests.swift`

- [ ] 6. Checkpoint
  - Ensure shaped-window reconstruction works behind the env flag; verify `HoloscapeSynthwave` (no `windowShape`) renders rectangular; verify `shaped.wamp` fixture produces a shaped window.

- [ ] 7. Click-through hit testing
  - [ ] 7.1 Create `HitRegionSampler`
    - Create `Sources/Holoscape/Services/HitRegionSampler.swift` with `struct HitRegionSampler`
    - Store `polygons: [Polygon]`
    - Implement `contains(_ point: CGPoint) -> Bool` via ray-casting (Jordan curve theorem) — returns true if point inside any polygon
    - Handle edges and vertices deterministically using the half-open interval convention
    - _Requirements: 3.1, 3.2, 3.4_

  - [ ] 7.2 Override `hitTest(_:)` on the shaped-window content view
    - Create `Sources/Holoscape/Views/ShapedContentView.swift` subclass of `NSView` used only when a shape is active
    - Store `hitRegionSampler: HitRegionSampler?`
    - Override `hitTest(_:)` to: (1) return nil if point is outside the sampler's covered regions; (2) otherwise delegate to `super.hitTest(_:)` to route into sub-views
    - Install `ShapedContentView` as the content view in `ShapedWindowController.reconstructWindow` when a shape is applied
    - _Requirements: 3.1, 3.3_

  - [ ] 7.3 Wire samplers from `MainWindowController`
    - In `MainWindowController.applySkin`, after shape reconstruction, construct `HitRegionSampler` from the resolved polygons and inject into the `ShapedContentView`
    - Tear down sampler on rectangular return
    - Post-MVP hook: when mask-image shapes ship (Phase 2), this call site adds a parallel `AlphaHitSampler` construction path; the injection surface is factored to accept either sampler
    - _Requirements: 3.1_

  - [ ]* 7.4 Unit tests for HitRegionSampler
    - Create `Tests/HoloscapeTests/Unit/HitRegionSamplerTests.swift`
    - Test inside / outside / on-edge / on-vertex classifications for triangles, squares, concave polygons, nested polygons
    - Test determinism across 100 repeated calls
    - _Requirements: 3.1, 3.2_

  - [ ]* 7.5 Property test: Hit region determinism
    - **Property 5: Hit region sampler is deterministic on vertices and edges**
    - **Validates: Requirements 3.2, 3.3**
    - Create `Tests/HoloscapePropertyTests/HitRegionDeterminismPropertyTests.swift`

- [ ] 8. Checkpoint
  - Ensure click-through works on `shaped.wamp` fixture; verify points outside the polygon pass mouse events to the system; verify points inside route into sub-views.

- [ ] 9. Skin-authored drag regions
  - [ ] 9.1 Create `DragRegionTracker`
    - Create `Sources/Holoscape/Controllers/DragRegionTracker.swift` with `@MainActor final class DragRegionTracker`
    - Store `weak var contentView: NSView?`, `regions: [ResolvedDragRegion]`, `trackingAreas: [NSTrackingArea]`
    - Implement `install()` — installs one `NSTrackingArea` per polygon's bounding rect
    - Implement `teardown()` — removes all `NSTrackingArea` instances
    - Implement `handleMouseDown(_:) -> Bool` — tests point against polygons, invokes `window.performDrag(with:)`, returns true on consumption
    - Implement `cursorForPoint(_:mouseDown:) -> NSCursor?` — returns `NSCursor.openHand` when hovering + mouse up, `NSCursor.closedHand` when hovering + mouse down
    - Define `ResolvedDragRegion` struct with `polygons: [Polygon]`, `modifier: Modifier` (`.none, .command`)
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.7_

  - [ ] 9.2 Wire drag-region routing into `ShapedContentView`
    - Modify `Sources/Holoscape/Views/ShapedContentView.swift` to override `mouseDown(with:)`; if `dragRegionTracker.handleMouseDown(event)` returns true, consume the event; otherwise call `super.mouseDown(with:)`
    - Override `cursorUpdate(with:)` to query `dragRegionTracker.cursorForPoint(...)` and push onto the cursor stack
    - Expose `dragRegionTracker: DragRegionTracker?` on the view
    - _Requirements: 4.1, 4.2, 4.3, 4.4_

  - [ ] 9.3 Wire drag-region installation into `MainWindowController.applySkin`
    - In `MainWindowController.applySkin`, after sampler injection, construct `ResolvedDragRegion` array from `manifest.dragRegions`, instantiate `DragRegionTracker`, call `install()`
    - Tear down previous tracker before installing new one
    - IF the window is borderless AND no `dragRegions` are declared, set `NSWindow.isMovableByWindowBackground = true` (Requirement 4.6 fallback)
    - _Requirements: 4.1, 4.6_

  - [ ] 9.4 Emit HIG violation warnings at skin-load time
    - In `SkinEngine.loadComposite`, after decoding `manifest.dragRegions`, walk each polygon's bounding box and `NSLog` a warning naming the polygon index when width or height is under 44 points
    - _Requirements: 4.5, 15.5_

  - [ ]* 9.5 Unit tests for DragRegionTracker
    - Create `Tests/HoloscapeTests/Unit/DragRegionTrackerTests.swift`
    - Test `handleMouseDown` returns true when point inside polygon, false when outside
    - Test cursor returns `openHand` on hover, `closedHand` on hover+mouseDown
    - Test modifier gate: `.command` requires `NSEvent.modifierFlags.contains(.command)` at mouseDown
    - Test teardown removes all tracking areas
    - _Requirements: 4.2, 4.3, 4.4, 4.7_

  - [ ]* 9.6 Property test: Drag region HIG warning
    - **Property 16: Drag region HIG warning fires on small bounds**
    - **Validates: Requirements 4.5, 15.5**
    - Create `Tests/HoloscapePropertyTests/DragRegionHIGWarningPropertyTests.swift`

- [ ] 10. Checkpoint
  - Ensure `shaped.wamp` with declared drag regions moves the window on mouseDown+drag; ensure no drag regions → entire content view draggable fallback; verify Mac Mini dogfood of drag UX.

- [ ] 11. Sprite-sheet fills
  - [ ] 11.1 Extend `SkinContext.applyFill` with sprite state parameter
    - Modify `Sources/Holoscape/Services/SkinContext.swift` `applyFill(to:from:backingScale:)` to take an additional `spriteState: SpriteState = .normal` parameter
    - When `resolved.fill` is `.image` with a non-nil `SpriteDescriptor`: assign the FULL sprite sheet to `layer.contents` once (idempotent — skip reassignment when already correct), then compute the normalized UV rectangle `CGRect(x: col * cellWidth / imageWidth, y: row * cellHeight / imageHeight, width: cellWidth / imageWidth, height: cellHeight / imageHeight)` and set `layer.contentsRect`. This keeps state transitions on the GPU side — no CGImage re-crop, no bitmap allocation per state — and plays correctly with `layer.contentsScale = backingScale` for Retina
    - Fall back to the `normal` cell when `spriteState` not in stateMap; fall back to the full sheet at `contentsRect = unit` (0,0,1,1) with `contentsGravity = .resize` when `normal` is also absent
    - _Requirements: 5.1, 5.3, 5.7_

  - [ ] 11.2 Validate sprite descriptor at load time
    - In `SkinEngine.loadComposite`, after `loadImages` succeeds, iterate surfaces with sprite descriptors; for each, call `SpriteDescriptor.isValid(imageSize:)` against the loaded image size
    - On invalid descriptor, log a dimension-mismatch warning and drop the sprite descriptor (fall back to stretch-mode fill) by rewriting the resolved surface's fill to `.image(path, .stretch, nil)` effectively
    - _Requirements: 5.4_

  - [ ] 11.3 Publish sprite state transitions from TabBarView
    - Modify `Sources/Holoscape/Views/TabBarView.swift` to install an `NSTrackingArea` on each tab button; on `mouseEntered` set `spriteState = .hover`, on `mouseExited` reset; on `mouseDown` set `.pressed`, on `mouseUp` reset
    - Write `spriteState.rawValue` into the per-tab `ReactiveUniformSnapshot`; call `refreshFromSkin()` on transition
    - In `refreshFromSkin()`, read current sprite state and pass to `applyFill(..., spriteState:)`
    - _Requirements: 5.2, 5.5_

  - [ ] 11.4 Publish sprite state transitions from SidebarView / SidebarTabEntry
    - Modify `Sources/Holoscape/Views/SidebarView.swift` and the SidebarTabEntry type to install tracking areas; publish hover/pressed state into the per-entry `ReactiveUniformSnapshot`
    - Call `refreshFromSkin()` on transition; apply sprite-aware fill
    - _Requirements: 5.2, 5.5_

  - [ ] 11.5 Publish sprite state transitions from SessionLauncherView
    - Modify `Sources/Holoscape/Views/SessionLauncherView.swift` similarly; install tracking areas on launcher button; publish state on transition
    - _Requirements: 5.2, 5.5_

  - [ ] 11.6 Honor density modes for sprite rendering
    - In `SkinContext.applyFill`, check `densityModeManager?.shouldRenderSprites() ?? true`; when false (minimal mode), skip the `contentsRect` UV computation and apply stretch-mode full-image fill (`contentsRect = unit`)
    - Add `shouldRenderSprites()` method to `DensityModeManager` returning `true` only for `.full`
    - _Requirements: 5.6, 11.2_

  - [ ]* 11.7 Unit tests for sprite cell selection
    - Create `Tests/HoloscapeTests/Unit/SpriteContentsRectTests.swift`
    - Test UV math at pixel boundaries (fixture: 2×2 grid of colored quadrants — `contentsRect` for each quadrant sampled on a colored fixture must return the matching color)
    - Test off-by-one at cell edges (UV values at the exact `row * cellHeight / imageHeight` seam)
    - Test fallback chain: missing state → normal → unit `contentsRect` with stretch gravity
    - Test invalid descriptor is rewritten to stretch at load time
    - Test that `layer.contents` is assigned exactly once per skin load and `contentsRect` is mutated on state transitions
    - _Requirements: 5.1, 5.3, 5.4_

  - [ ]* 11.8 Property test: Sprite cell selection covers exactly the declared cell
    - **Property 6: Sprite cell selection covers exactly the declared cell**
    - **Validates: Requirements 5.1, 5.4, 5.7**
    - Create `Tests/HoloscapePropertyTests/SpriteContentsRectPropertyTests.swift`
    - Generate arbitrary `SpriteDescriptor` + state combinations; assert computed `contentsRect` has `minX, minY, maxX, maxY ∈ [0, 1]`, covers exactly the expected pixel cell under the image's dimensions, and never references pixels outside the sheet

  - [ ]* 11.9 Property test: Sprite state transition latency
    - **Property 7: Sprite state transitions reapply within 16 ms**
    - **Validates: Requirements 5.2**
    - Create `Tests/HoloscapePropertyTests/SpriteLatencyPropertyTests.swift`
    - Measures state-change-event → `layer.contentsRect` mutation round trip (no bitmap work expected on the hot path)
    - Mark this test as optional — if flaky on CI, document the expected wall-clock behavior and skip

- [ ] 12. Checkpoint
  - Ensure tab buttons, sidebar rows, and launcher buttons swap sprite cells on hover/press by mutating `layer.contentsRect` (the full sheet is assigned to `layer.contents` exactly once per skin load); verify density `.minimal` short-circuits to stretch mode; verify `HoloscapeSynthwave` (no sprite descriptors) renders unchanged.

- [ ] 13. Chrome font consumption
  - [ ] 13.1 Add `resolvedFont` helper to `SkinContext`
    - Modify `Sources/Holoscape/Services/SkinContext.swift` to add `resolvedFont(for:spriteState:) -> NSFont?`
    - Resolution order: (1) check `fontRegistry` for `family`; (2) try `NSFont(name: family, size: size)`; (3) fall back to `NSFont.monospacedSystemFont(ofSize:weight:)`
    - Parse `weight` string to `NSFont.Weight`; unknown weight → `.regular`
    - The `fontRegistry` populating this lookup is produced by `SkinEngine.registerFonts(from:)`, which MUST register via `CTFontManagerRegisterFontsForURL(_, .process, _)` (no `.persistent` scope — skin fonts must not appear in Font Book or outlive the process per Requirements 6.7, 6.8)
    - _Requirements: 6.1, 6.4, 6.6, 6.7, 6.8_

  - [ ] 13.2 Consume fonts in TabBarView, SidebarView, InputBoxView, SessionLauncherView
    - Modify `Sources/Holoscape/Views/TabBarView.swift` `refreshFromSkin()` to resolve `skinContext.resolvedFont(for: .tabBarTabActive)` (and siblings) and apply to tab label `NSTextField` instances
    - Modify `Sources/Holoscape/Views/SidebarView.swift` `refreshFromSkin()` to apply resolved font to sidebar row labels
    - Modify `Sources/Holoscape/Views/InputBoxView.swift` `refreshFromSkin()` to apply resolved font to input field and placeholder
    - Modify `Sources/Holoscape/Views/SessionLauncherView.swift` `refreshFromSkin()` to apply resolved font to session rows and button titles
    - When no font in manifest, retain pre-Amplify system font (do not touch the font property)
    - _Requirements: 6.2, 6.3, 6.5_

  - [ ]* 13.3 Property test: Font fallback terminates
    - **Property 8: Font fallback terminates**
    - **Validates: Requirements 6.4**
    - Create `Tests/HoloscapePropertyTests/FontFallbackPropertyTests.swift`

  - [ ]* 13.4 Property test: Font registration symmetry extended
    - **Property 11: Font registration symmetry**
    - **Validates: Requirements 6.7, 6.8 (extended for `.wamp` path)**
    - Extend `Tests/HoloscapePropertyTests/FontRegistrationSymmetryPropertyTests.swift` to cover the `.wamp` unzip + register sequence. Assert that across any sequence of register/unregister calls against `.wamp` bundles, the process-scope `CTFontManager` registration set contains exactly the fonts of the currently-active skin (zero leaks), and that no scope other than `.process` is ever touched

- [ ] 14. Checkpoint
  - Ensure tab / sidebar / input / launcher render in skin-defined fonts when a manifest declares them; verify fallback to system font when manifest omits font; verify `HoloscapeSynthwave` uses its pre-Amplify font behavior.

- [ ] 15. Chrome border, corner, and shadow consumption
  - [ ] 15.1 Add `applyShadow` helper to `SkinContext`
    - Modify `Sources/Holoscape/Services/SkinContext.swift` to add `applyShadow(to layer: CALayer, from resolved: ResolvedSurface)`
    - Apply `layer.shadowColor / shadowOpacity / shadowRadius / shadowOffset` from `resolved.shadow`
    - When `resolved.shadow` is nil, set `shadowOpacity = 0`
    - Extract existing shadow code from `applyBorderAndCorner` into this helper; keep `applyBorderAndCorner` calling `applyShadow` for backward compat
    - _Requirements: 7.1, 7.2, 7.3_

  - [ ] 15.2 Apply border/corner/shadow in TabBarView, SidebarView, InputBoxView, SessionLauncherView
    - Modify `Sources/Holoscape/Views/TabBarView.swift` `refreshFromSkin()` to call `applyBorderAndCorner` and `applyShadow` on tab button layers; apply pill-shape corner clamp (if `.uniform` radius > tab height / 2, clamp to tab height / 2)
    - Modify `Sources/Holoscape/Views/SidebarView.swift` `refreshFromSkin()` to apply border/corner/shadow on sidebar row layers
    - Modify `Sources/Holoscape/Views/InputBoxView.swift` `refreshFromSkin()` to apply border/corner/shadow on input box layer
    - Modify `Sources/Holoscape/Views/SessionLauncherView.swift` `refreshFromSkin()` to apply border/corner/shadow on launcher container and button layers
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

  - [ ]* 15.3 Unit test for pill-shape corner clamp
    - Extend `Tests/HoloscapeTests/Unit/TabBarViewSkinContextTests.swift` to test that `.uniform(9999)` on a 30pt-tall tab clamps to 15pt
    - _Requirements: 7.5_

- [ ] 16. Checkpoint
  - Ensure skinned chrome views render with borders, corners, shadows from the manifest; verify `HoloscapeSynthwave` still renders (no skin-defined border/corner → no-op).

- [ ] 17. Reader panel skinning
  - [ ] 17.1 Accept skin context in ReaderModeController
    - Modify `Sources/Holoscape/Controllers/ReaderModeController.swift` to add `weak var skinContext: SkinContext?` property
    - Wire injection from `MainWindowController` (pass the current context when opening Reader Mode)
    - _Requirements: 8.1_

  - [ ] 17.2 Apply Reader panel surfaces
    - In `ReaderModeController.open()`, resolve `readerPanelBackground`, `readerPanelTitleBar`, `readerPanelCloseButtonNormal/hover/pressed` via `skinContext`
    - Apply fills, borders, corners, shadows via `applyFill`, `applyBorderAndCorner`, `applyShadow` on the corresponding layers
    - When no surface is defined, retain the pre-Amplify Reader Mode look (no-op)
    - _Requirements: 8.1, 8.2, 8.4, 8.5_

  - [ ] 17.3 Apply Reader panel font
    - In `ReaderModeController.open()`, resolve `readerPanelBackground.font` via `skinContext.resolvedFont(for: .readerPanelBackground)` and apply to the text view
    - When resolved font is nil, retain hardcoded `NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)`
    - Check `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`; when true, ignore skin font and use SF Mono 14pt regardless
    - _Requirements: 8.3, 8.6, 15.3_

  - [ ]* 17.4 Unit tests for Reader panel skinning
    - Create `Tests/HoloscapeTests/Unit/ReaderModeSkinningTests.swift`
    - Test font applied when `readerPanelBackground.font` is defined
    - Test fallback to SF Mono when surface absent
    - Test Increase Contrast overrides skin font
    - _Requirements: 8.3, 8.4, 8.6_

- [ ] 18. Checkpoint
  - Ensure Reader Mode renders in the skin's fonts and chrome when surfaces are defined; verify fallback to SF Mono 14pt when surfaces absent; verify Increase Contrast override.

- [ ] 19. Reference skins
  - [ ] 19.1 Repackage HoloscapeSynthwave as `.wamp`
    - Create `Tools/package_synthwave.sh` script that zips `Sources/Holoscape/Resources/Skins/HoloscapeSynthwave/` into `Sources/Holoscape/Resources/Skins/HoloscapeSynthwave.wamp`
    - Add `HoloscapeSynthwave.wamp` to `Package.swift` resources under `Resources/Skins`
    - Leave the directory-layout HoloscapeSynthwave in place (both should resolve; user dir wins per Requirement 1.7)
    - _Requirements: 16.7_

  - [ ] 19.2 Author `HoloscapeClassic.wamp` manifest
    - Create `Tools/holoscape_classic/` scaffolding: `skin.json` with `version: "3.0"`, a `windowShape` with polygons (rectangular-with-cut-corners), one sprite-sheet surface with `normal/hover/pressed` cells, one `dragRegion`, border/corner/shadow on the tab bar, a `fonts/` directory with one pixel-style TTF referenced by `tabBarTabActive.font`
    - Erik sources the art; Tools/holoscape_classic/ may ship with a procedural placeholder PNG until then (generated via a Bash script or check-in as a low-fi bitmap)
    - Bundle the resulting `HoloscapeClassic.wamp` into `Sources/Holoscape/Resources/Skins/`
    - _Requirements: 16.1, 16.2, 16.3, 16.4, 16.5, 16.6_

  - [ ] 19.3 Integration test: backward-compat round-trip
    - Create `Tests/HoloscapeTests/Integration/BackwardCompatIntegrationTests.swift`
    - Test: load `HoloscapeSynthwave` directory-layout; capture resolved `Skin_Context`; load `HoloscapeSynthwave.wamp`; capture resolved `Skin_Context`; assert equal surfaces map, equal font PostScript names, equal image hashes
    - _Requirements: 9.1, 9.3, 9.4, 16.7_

  - [ ] 19.4 Integration test: HoloscapeClassic exercises every Amplify feature
    - Extend `Tests/HoloscapeTests/Integration/WampLoadIntegrationTests.swift` with a test that loads `HoloscapeClassic.wamp` and verifies: shape applied, at least one sprite surface resolved, at least one drag region installed, at least one registered skin font, border/corner/shadow applied to at least one chrome view
    - _Requirements: 16.1-16.6_

- [ ] 20. Checkpoint
  - Dogfood HoloscapeClassic on Mac Mini; confirm shape, sprites, drag region, font, bevels all render; confirm HoloscapeSynthwave (both directory and `.wamp`) still renders identically to pre-Amplify.

- [ ] 21. Hot reload, degradation, and docs
  - [ ] 21.1 Extend hot reload for `.wamp`
    - Verify `SkinEngine.startWatching(skinName:)` installs on the `.wamp` file's parent directory and filters to the bundle path (done in Task 3.6; this task adds explicit test coverage)
    - On watcher fire, `WampBundleLoader.contentHash` is recomputed; if hash matches, skip unzip; if hash changes, re-unzip and rebuild `SkinContext`
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6_

  - [ ] 21.2 Malformed-skin banner notification
    - Create `Sources/Holoscape/Views/SkinWarningBanner.swift` subclass of `NSView`
    - In `MainWindowController.applySkin`, when `LoadedSkin.validationBannerReason` is non-nil, instantiate the banner atop the window for 5 seconds with the reason string
    - Respect Reduce Motion: skip the fade animation when true
    - Banner text is VoiceOver-readable (set `accessibilityLabel`)
    - _Requirements: 13.2, 13.6, 15.4_

  - [ ] 21.3 Sprite / font / drag-region degradation logging
    - Verify every fallback path (missing sprite image, missing font, malformed drag region) logs exactly one warning line naming the offending path or index (Principle 5 of Error Handling)
    - Audit existing log call sites; add missing ones
    - _Requirements: 13.3, 13.4, 13.5_

  - [ ] 21.4 Write `docs/amplify-format.md`
    - Create `docs/amplify-format.md` covering: `.wamp` bundle layout, every Amplify manifest field with JSON examples, `WindowShapeDescriptor` coordinate system, `SpriteDescriptor` state map, `DragRegionDescriptor` semantics, expanded `SurfaceKey` catalog (36 cases), every failure mode with user-visible behavior
    - Include an illustrated example using `HoloscapeClassic` as the worked example
    - _Requirements: 17.1, 17.2, 17.3_

  - [ ] 21.5 Update parent chrome-skinning spec
    - Modify `claude-specs/chrome-skinning/tasks.md` to mark Amplify as the follow-up spec; link `claude-specs/amplify/` from the parent
    - _Requirements: 17.4_

  - [ ]* 21.6 Integration test for hot reload of `.wamp`
    - Extend `Tests/HoloscapeTests/Integration/HotReloadTests.swift` with a test that modifies a staged `.wamp` file in place and asserts the chrome updates within 200 ms
    - _Requirements: 10.6_

  - [ ]* 21.7 Property test: Density `.off` bypasses every Amplify code path
    - **Property 10: Density .off bypasses every Amplify code path**
    - **Validates: Requirements 11.1, 14.4**
    - Create `Tests/HoloscapePropertyTests/AmplifyDensityOffPropertyTests.swift`

  - [ ]* 21.8 Property test: Graceful degradation preserves previous context
    - **Property 13: Graceful degradation preserves previous context**
    - **Validates: Requirements 1.5, 13.1, 13.2, 13.3, 13.4, 13.5**
    - Create `Tests/HoloscapePropertyTests/GracefulDegradationPropertyTests.swift`

  - [ ]* 21.9 Property test: Accessibility preferences always override
    - **Property 15: Accessibility preferences always override**
    - **Validates: Requirements 2.9, 8.6, 15.1, 15.3**
    - Create `Tests/HoloscapePropertyTests/AccessibilityOverridePropertyTests.swift`

- [ ] 22. Final checkpoint
  - Run full test suite: `swift test` must pass; `swift build -c release` must succeed; `./bundle.sh` must produce a valid `.app`
  - Mac Mini dogfood: switch between Default, HoloscapeSynthwave (directory), HoloscapeSynthwave.wamp, and HoloscapeClassic.wamp multiple times; verify no hot-reload glitches, no frame jumps, no font leaks, no orphaned tracking areas
  - Verify backward-compat: every chrome-skinning test in `claude-specs/chrome-skinning/` continues to pass unchanged
  - Verify performance budgets: cold `.wamp` load under 500 ms, warm load under 150 ms, shaped-window idle CPU overhead under 5%, density-off zero CPU overhead, `Hit_Region_Sampler` under 100 microseconds per point for polygons up to 64 vertices
  - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5_

## Notes

- Tasks marked with `*` are optional property and integration tests; they can be skipped for a faster MVP but every property from design.md has a corresponding optional task for eventual coverage.
- Each task references specific requirements via `_Requirements: X.Y_` tags for traceability.
- Checkpoints (Tasks 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22) ensure incremental validation against the backward-compat contract and match the PRD §12 PR sequence.
- The `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` env flag gates Task Groups 5, 7, and 9 so shaped-window bugs can be isolated without reverting the whole PR.
- Art for `HoloscapeClassic` is Erik's track (sourced or commissioned); the spec ships with a procedural placeholder so the engine can be tested without blocking on art.
