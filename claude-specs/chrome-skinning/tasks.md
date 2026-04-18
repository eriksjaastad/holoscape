# Implementation Plan: Chrome Skinning System

## Overview

This plan breaks the Chrome Skinning System into 10 task groups covering: data model extensions, core services (SkinContext, AnimationEngine, ReactiveUniformSnapshot, DensityModeManager, ChromeRegionManager, ReaderModeController), chrome view migrations (6 views), image/font asset pipeline, hot reload, and the built-in reference skin. Tasks follow the project's Swift/AppKit conventions with `Codable, Equatable, Sendable` models and `@MainActor final class` services. Property tests use SwiftCheck; unit and integration tests use XCTest.

The implementation order is: data models → core services → chrome view migrations → asset pipeline → hot reload + reactivity → reference skin. Checkpoints validate incremental progress.

## Tasks

- [x] 1. Data model extensions
  - [x] 1.1 Extend `SkinDefinition` with v2 optional fields
    - Modify `Sources/Holoscape/Models/SkinDefinition.swift` to add optional `version`, `name`, `author`, `description` string fields
    - Add optional `surfaces: [String: SurfaceDescriptor]?` dictionary field keyed by SurfaceKey raw value
    - Keep all 10 existing v1 fields unchanged
    - _Requirements: 1.2, 1.3, 1.4_

  - [x] 1.2 Create `SurfaceKey` enum
    - Create `Sources/Holoscape/Models/SurfaceKey.swift` with an enum `SurfaceKey: String, CaseIterable`
    - Add 23 cases matching the surface catalog from `docs/skins/06-chrome-skinning.md` §6
    - Use dot-separated raw values: `windowBackground = "window.background"`, etc.
    - _Requirements: 3.4_

  - [x] 1.3 Create descriptor types
    - Create `Sources/Holoscape/Models/SurfaceDescriptor.swift` with `SurfaceDescriptor`, `FillDescriptor`, `BorderDescriptor`, `CornerDescriptor`, `PaddingDescriptor`, `ShadowDescriptor`, `FontDescriptor`, `TextDescriptor`, `AnimationDescriptor`, `CurveDescriptor`, `StateVariant`, `MatchExpression`, `GradientStop`
    - All types `Codable, Equatable, Sendable`
    - `FillDescriptor` is an enum with `color`, `image`, `gradient` cases
    - `CornerDescriptor` is an enum with `uniform` and `asymmetric` cases
    - _Requirements: 2.1, 2.2, 2.4, 2.5_

  - [x] 1.4 Create `NinepatchSidecar` and `ChromeRegionState` models
    - Create `Sources/Holoscape/Models/NinepatchSidecar.swift` with `stretchX: [Int]` and `stretchY: [Int]` fields
    - Add `ChromeRegionState` struct to `Sources/Holoscape/Models/HoloscapeConfig.swift` alongside existing V3 config types
    - Wire `ChromeRegionState` into `HoloscapeConfig` as an optional field for backward compatibility
    - _Requirements: 2.3, 9.4, 10.5_

  - [x]* 1.5 Unit tests for v1/v2 codable round-trip
    - Create `Tests/HoloscapeTests/Unit/SkinDefinitionV2Tests.swift`
    - Test v1 manifest decodes without v2 fields, produces nil `surfaces`
    - Test v2 manifest decodes both v1 fields and v2 `surfaces` dictionary
    - Test unknown fields are ignored (forward compat)
    - _Requirements: 1.2, 1.3_

  - [x]* 1.6 Property test: V1 backward compatibility
    - **Property 1: V1 skin backward compatibility**
    - **Validates: Requirements 1.1, 1.2, 1.3, 1.4**
    - Shipped as `Tests/HoloscapePropertyTests/V1CompatibilityPropertyTests.swift` (flat layout, matching the existing property-test convention)
    - Generates random v1 manifests via SwiftCheck, round-trips through Codable, asserts `SkinEngine.apply(skin:to:)` transfers `windowBackground` / `ansiColors` (16 entries only) / `textForeground`, and that unknown top-level keys decode without error

  - [x]* 1.7 Unit tests for SurfaceKey exhaustiveness
    - Create `Tests/HoloscapeTests/Unit/SurfaceKeyTests.swift`
    - Assert `SurfaceKey.allCases.count == 23`
    - Assert every raw value is unique and non-empty
    - _Requirements: 3.4_

  - [x]* 1.8 Unit tests for malformed manifest handling
    - Create `Tests/HoloscapeTests/Unit/SkinDefinitionErrorTests.swift`
    - Test invalid JSON is rejected with logged error
    - Test malformed v2 surfaces dictionary is gracefully skipped
    - Test fallback to v1 or built-in defaults on parse failure
    - _Requirements: 1.5_

- [x] 2. Checkpoint
  - Ensure all tests pass. Verify SkinDefinition still loads existing v1 skin.json files without regression.

- [x] 3. SkinContext and core resolver
  - [x] 3.1 Create `SkinContext` class with ResolvedSurface
    - Create `Sources/Holoscape/Services/SkinContext.swift` as `@MainActor final class`
    - Add `ResolvedSurface` struct with `fill: ResolvedFill`, `border`, `corner`, `padding`, `shadow`, `font`, `text`, `animation`, `states` fields
    - Add `surfaces: [SurfaceKey: ResolvedSurface]` dictionary
    - Add `reactive: ReactiveUniformSnapshot` reference (will be wired in task 4.1)
    - Add `fontRegistry: [String: CGFont]` and `imageCache: [String: NSImage]` properties
    - _Requirements: 3.1, 3.2, 3.5_

  - [x] 3.2 Implement `resolve(_:)` and `currentState(for:)` methods
    - `resolve(_ key: SurfaceKey) -> ResolvedSurface` returns resolved surface or built-in default
    - `currentState(for key: SurfaceKey) -> ResolvedSurface` evaluates state variants against current snapshot and returns merged result
    - Built-in defaults match the existing hardcoded colors per view
    - Also adds `currentState(for:with snapshot:)` override so callers (e.g. per-entry sidebar rows) can resolve against a specific snapshot rather than the context's shared one (2026-04-18, PR #108)
    - _Requirements: 3.3_

  - [x] 3.3 Implement `applyFill(to:from:)` and `applyBorderAndCorner(to:from:)`
    - `applyFill(to layer: CALayer, from resolved: ResolvedSurface)` — handles color, image, gradient variants
    - For gradient fills, insert a `CAGradientLayer` sublayer into the target layer
    - For image fills with ninepatch, set `layer.contentsCenter` from the sidecar
    - `applyBorderAndCorner` sets `borderColor`, `borderWidth`, `cornerRadius`, shadow properties
    - Also takes `backingScale:` parameter so callers pass `window?.backingScaleFactor` for HiDPI image fills (Task 8.5, PR #102)
    - _Requirements: 2.6, 7.2_

  - [x] 3.4 Implement match expression evaluator
    - Add private `evaluateMatch(_ expr: MatchExpression) -> Bool` method
    - Support match keys: `agentState`, `previousAgentState`, `commandState`, `previousCommandState`, `lastCommandExitCode`, `channelId`, `channelIsActive`, `channelUnread`, `notificationKind`, `timeSince`
    - Support operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`; bare scalar is `$eq` shorthand
    - Multi-key matches combined with logical AND
    - Unknown keys/operators logged and skipped (no crash)
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

  - [x]* 3.5 Property test: State variant determinism
    - **Property 5: State variant determinism**
    - **Validates: Requirements 12.1, 12.2, 12.4, 12.5, 12.6**
    - Shipped as `Tests/HoloscapePropertyTests/StateDeterminismPropertyTests.swift`
    - Evaluates `currentState(for:with:)` 10 times per random `(SurfaceKey, snapshot)` pair and asserts all 10 results are equal; a cheaper companion property tests `evaluateMatch` directly for the same determinism invariant

  - [x]* 3.6 Property test: Match operator totality
    - **Property 6: Match operator totality**
    - **Validates: Requirement 12.3**
    - Shipped as `Tests/HoloscapePropertyTests/OperatorTotalityPropertyTests.swift`
    - Hammers `evaluateMatch` with random (key, operator, value) triples spanning known and unknown keys/operators, bare-scalar shorthand, multi-key AND, and `timeSince` expressions; every call must return a `Bool`

  - [x]* 3.7 Unit tests for SkinContext resolution
    - Create `Tests/HoloscapeTests/Unit/SkinContextResolutionTests.swift`
    - Test default fallback when surface not in manifest
    - Test v1→v2 merge semantics (child overrides parent)
    - Test state variant evaluation with last-match-wins CSS cascade semantics
    - _Requirements: 3.3, 12.4_

  - [x]* 3.8 Property test: State snapshot consistency
    - **Property 15: State snapshot consistency**
    - **Validates: Requirements 12.1, 12.2, 12.5, 12.6**
    - Shipped as `Tests/HoloscapePropertyTests/StateSnapshotConsistencyPropertyTests.swift`
    - Covers the CHROME half of Property 15 (documented match keys resolve via `intValue(forMatchKey:)`; documented timestamp uniforms resolve via `timestamp(named:)`; unknown keys return nil; double-reads agree). The shader half (chrome↔shader cross-reader agreement) is deferred to card #5945; once that lands, a cross-reader consistency test can join this file.

- [x] 4. ReactiveUniformSnapshot
  - [x] 4.1 Create `ReactiveUniformSnapshot` with atomic fields
    - Create `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift` as `final class ReactiveUniformSnapshot: @unchecked Sendable`
    - Use atomic-backed properties for `agentState`, `previousAgentState`, `commandState`, `channelUnread`, `notificationKind` (Int32)
    - Use atomic-backed properties for `timeAgentStateChange`, `timeLastOutput`, `timeCommandStart`, `timeCommandEnd`, `timeLastNotification` (Double via bitcast)
    - Match the field set from `docs/skins/05-reactive-uniforms.md` §5
    - _Requirements: 12.6_

  - [x] 4.2 Implement `stampTransition` method
    - Enum `TimestampField` with cases for each timestamp field
    - `stampTransition(_ field: TimestampField)` writes `CFAbsoluteTimeGetCurrent()` to the corresponding field atomically
    - _Requirements: 12.5, 12.6_

  - [x]* 4.3 Unit tests for atomic reads across threads
    - Create `Tests/HoloscapeTests/Unit/ReactiveUniformSnapshotTests.swift`
    - Test concurrent writes from multiple threads produce observable atomic writes
    - Test timestamp stamping is monotonic per field
    - _Requirements: 12.6_

- [x] 5. AnimationEngine
  - [x] 5.1 Create `AnimationEngine` class
    - Create `Sources/Holoscape/Services/AnimationEngine.swift` as `@MainActor final class`
    - Add `displayLink: CADisplayLink?` property (initially nil)
    - Add `activeAnimations: [AnimationID: AnimationState]` dictionary
    - `animateSurface(_:to:on:with:)` method queues animation and starts display link if needed
    - _Requirements: 13.1, 13.3_

  - [x] 5.2 Implement curve translation
    - Map curve string values to `CAMediaTimingFunction` instances: `linear`, `easeIn`, `easeOut`, `easeInOut`
    - For `spring`, use `CASpringAnimation` instead of `CABasicAnimation`
    - Per-property overrides (fill/corner) take precedence over default curve
    - _Requirements: 13.2, 13.4_

  - [x] 5.3 Implement display link lifecycle
    - `startDisplayLinkIfNeeded()` — creates and starts if any active animations
    - `stopDisplayLinkIfIdle()` — invalidates and nils when no active animations remain
    - `suppressAll()` — immediately completes all animations for density mode transition
    - _Requirements: 13.3, 13.5_

  - [x]* 5.4 Unit tests for AnimationEngine lifecycle
    - Create `Tests/HoloscapeTests/Unit/AnimationEngineTests.swift`
    - Test display link starts when first animation queued
    - Test display link stops when all animations complete
    - Test suppression in minimal mode applies final state instantly
    - _Requirements: 13.3, 13.5_

  - [x]* 5.5 Property test: Display link idleness
    - **Property 8: Display link idleness**
    - **Validates: Requirements 13.3, 15.4**
    - Shipped as `Tests/HoloscapePropertyTests/DisplayLinkIdlenessPropertyTests.swift`
    - Generates random operation sequences (animate / complete / suppress) and asserts the per-step invariant `activeAnimations.isEmpty ⇒ displayLink == nil`. A host-view-backed smoke test covers the create-on-active direction that the window-less property case can't observe (AnimationEngine's `startDisplayLinkIfNeeded` short-circuits on missing hostView).

- [x] 6. Checkpoint
  - Ensure all tests pass. Verify SkinContext, ReactiveUniformSnapshot, and AnimationEngine compile and interact correctly via unit tests.

- [x] 7. Density and region management
  - [x] 7.1 Create `DensityModeManager`
    - Create `Sources/Holoscape/Services/DensityModeManager.swift` as `@MainActor final class`
    - `Mode` enum with `.full`, `.minimal`, `.off` cases, Codable
    - `setMode(_ newMode: Mode)` completes the transition within 200ms (Req 10.2 is a latency cap, not an animation duration — a synchronous state change + chrome re-layout trivially satisfies it)
    - `isSkinActive()`, `shouldRenderImages()`, `shouldAnimate()` query methods
    - Persist mode to `HoloscapeConfig.chromeRegions.densityMode` (field already exists on `ChromeRegionState`)
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_

  - [x]* 7.1b Property test: Animation suppression leakage
    - **Property 16: No animation suppression leakage**
    - **Validates: Requirements 13.5, 13.1, 13.2, 13.4**
    - Shipped as `Tests/HoloscapePropertyTests/AnimationSuppressionLeakagePropertyTests.swift`
    - Runs random `Full → (Minimal|Off) → Full` sequences with variable animation counts per phase and asserts that returning to Full never replays suppressed animations. A companion property ensures queueing during non-full modes never populates the active set regardless of call count.

  - [x] 7.2 Wire DensityModeManager into AnimationEngine and SkinEngine
    - Modify `AnimationEngine` to query `densityModeManager.shouldAnimate()` before starting animations
    - Modify `SkinEngine` to short-circuit loading when mode is `.off`
    - Modify `SkinContext` to skip image fills when mode is `.minimal`
    - Covered by `SkinEngineDensityGateTests.swift`
    - _Requirements: 10.3, 10.4_

  - [x] 7.3 Create `ChromeRegionManager`
    - Create `Sources/Holoscape/Controllers/ChromeRegionManager.swift` as `@MainActor final class`
    - `Region` enum with `.top`, `.right`, `.bottom`, `.left` cases
    - `collapsedRegions: Set<Region>` property
    - `toggleRegion`, `collapseRegion(animated:)`, `expandRegion(animated:)` methods
    - _Requirements: 9.1, 9.2, 9.3_

  - [x] 7.4 Implement region collapse animation
    - 200ms ease-out slide using `NSLayoutConstraint` animation or `NSAnimationContext`
    - Terminal viewport expands to fill freed space via constraint priority adjustment
    - _Requirements: 9.2, 9.3_

  - [x] 7.5 Persist region state to HoloscapeConfig
    - Call `persistState()` on region toggle
    - Call `restoreState()` on app launch from `MainWindowController.init`
    - _Requirements: 9.4, 9.5_

  - [x] 7.6 Add View menu items for region toggle
    - Modify `Sources/Holoscape/AppDelegate.swift` to add "Top Chrome", "Right Chrome", "Bottom Chrome", "Left Chrome" items under View menu
    - Each item calls `ChromeRegionManager.toggleRegion`
    - _Requirements: 9.6_

  - [x]* 7.7 Unit tests for ChromeRegionManager
    - Create `Tests/HoloscapeTests/Unit/ChromeRegionManagerTests.swift`
    - Test collapse/expand, persistence round-trip, animation duration
    - _Requirements: 9.2, 9.3, 9.4_

  - [x]* 7.8 Unit tests for DensityModeManager
    - Create `Tests/HoloscapeTests/Unit/DensityModeManagerTests.swift`
    - Test mode transitions complete under 200ms
    - Test animation suppression in minimal/off modes
    - _Requirements: 10.2, 10.4_

- [x] 8. Asset pipeline (images and fonts)
  - [x] 8.1 Implement image loading in SkinEngine
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to add `loadImages(from:manifest:) -> [String: NSImage]` method
    - Load all referenced PNG images via `NSImage(contentsOfFile:)` at skin-apply time
    - Cache per-skin in SkinContext
    - Release on skin unload
    - Covered by `SkinEngineAssetLoadingTests.swift` (PR #99)
    - _Requirements: 1.7, 7.1, 7.4_

  - [x] 8.2 Implement ninepatch sidecar loading
    - Add `loadNinepatchSidecar(for imagePath:) -> NinepatchSidecar?` to SkinEngine
    - For image at `assets/tab-bg.png`, look for `assets/tab-bg.ninepatch.json`
    - When sidecar exists, auto-apply ninepatch tile mode via `CALayer.contentsCenter`
    - Covered by `NinepatchSidecarLoadingTests.swift` (PR #100)
    - _Requirements: 2.3, 7.2_

  - [x] 8.3 Implement asset path validation
    - Add `validateAssetPath(_ path: String) throws` to SkinEngine
    - Reject paths containing `..`, absolute paths, `http://`, `https://` URLs
    - Throw before any file system access
    - Two-layer sandbox: `validateAssetPath` catches string-shape escapes; `assertPathResolvesInside` resolves symlinks and blocks any path that escapes the skin directory. Belt-and-suspenders — neither alone is sufficient. (PR #99)
    - _Requirements: 1.6_

  - [x] 8.4 Implement font loading and registration
    - Modify `SkinEngine.registerFonts(from fontDirectory:)` to scan `assets/fonts/` for `.otf` and `.ttf` files
    - Register via `CTFontManagerRegisterFontsForURL` with process scope
    - Return `[String: CGFont]` map
    - On skin unload, call `CTFontManagerUnregisterFontsForURL` — MUST pass `SkinFontBundle.registeredURLs` (exactly what was registered) for symmetric drain. Rollback on CGFont-decode failure after a successful register; rollback failures log loudly. (PR #101)
    - Fall back to system default on load failure
    - Covered by `SkinEngineFontRegistrationTests.swift`
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

  - [x]* 8.4b Property test: Font registration symmetry
    - **Property 9: Font registration symmetry**
    - **Validates: Requirement 8.3**
    - Shipped as `Tests/HoloscapePropertyTests/FontRegistrationSymmetryPropertyTests.swift`
    - Runs `register(dir) → unregister → register(dir)` on random directories containing a mix of valid fonts (copies of `/System/Library/Fonts/Menlo.ttc`), corrupt `.ttf` files, and non-font siblings. The registered URL sets from both cycles must be identical — a leaked registration from cycle 1 would block cycle 2's re-register. Runs with `maxAllowableSuccessfulTests: 15` because each iteration does a full round-trip with disk I/O.

  - [x] 8.5 Wire backing scale factor to image layers
    - `SkinContext.applyFill(to:from:backingScale:)` takes a `backingScale` parameter; callers pass `layer.window?.backingScaleFactor ?? 2.0` (PR #102)
    - _Requirements: 7.3_

  - [x]* 8.6 Property test: Asset path sandboxing
    - **Property 2: Asset path sandboxing**
    - **Validates: Requirement 1.6**
    - Shipped as `Tests/HoloscapePropertyTests/PathSandboxingPropertyTests.swift`
    - Four properties cover the shape space: absolute paths, `http://` / `https://` / `file://` URLs (case-insensitive), any path containing a `..` segment, and a negative-control property that safe relative paths DO pass. Every rejection must carry the offending path in the thrown `SkinAssetError.invalidPath` so logs point at the right string.

  - [x]* 8.7 Unit tests for ninepatch loading
    - Create `Tests/HoloscapeTests/Unit/NinepatchSidecarTests.swift` (shipped as `NinepatchSidecarLoadingTests.swift`)
    - Test valid sidecar loads correctly
    - Test invalid ranges (stretchX[0] >= stretchX[1]) rejected
    - _Requirements: 2.3_

- [x] 9. Chrome view migrations
  - [x] 9.1 Migrate TabBarView to SkinContext
    - Modify `Sources/Holoscape/Views/TabBarView.swift` to accept `skinContext: SkinContext` in init
    - Delete 9 hardcoded NSColor constants
    - Resolve container, active tab, idle tab, permission tab, normal tab, unread marker surfaces via `skinContext.currentState(for:)`
    - Apply via `skinContext.applyFill(to:from:)` in `layout()` override
    - Observe `SkinDidChange` notification to re-layout
    - Covered by `TabBarViewSkinContextTests.swift` (PR #103)
    - _Requirements: 3.6, 4.1, 4.2, 4.3, 4.4, 4.5_

  - [x] 9.2 Migrate SidebarView to SkinContext
    - Modify `Sources/Holoscape/Views/SidebarView.swift` to accept `skinContext: SkinContext`
    - Delete 18 hardcoded NSColor constants across `SidebarView` and nested `SidebarTabEntry`
    - Resolve container, row states (normal/selected/hover), indicator, section header surfaces
    - Preserve scroll behavior via `NSScrollView` (no change)
    - Base fills shipped in PR #105; per-entry `ReactiveUniformSnapshot` on `SidebarTabEntry` finished the 8 deferred notification/indicator state colors via state variants (PR #108). Each entry owns its own snapshot so two rows with different unread flags resolve to different colors at the same instant.
    - Covered by `SidebarViewSkinContextTests.swift`
    - _Requirements: 3.6, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_

  - [x] 9.3 Migrate InputBoxView to SkinContext
    - Modify `Sources/Holoscape/Views/InputBoxView.swift` to accept `skinContext: SkinContext`
    - Delete 3 hardcoded NSColor constants
    - Resolve container, field, placeholder surfaces
    - Covered by `SmallViewsSkinContextTests.swift` (PR #104)
    - _Requirements: 3.6, 6.3_

  - [x] 9.4 Migrate SessionLauncherView to SkinContext
    - Modify `Sources/Holoscape/Views/SessionLauncherView.swift` to accept `skinContext: SkinContext`
    - Delete 1 hardcoded NSColor constant
    - Resolve container and row surfaces
    - Covered by `SmallViewsSkinContextTests.swift` (PR #104)
    - _Requirements: 3.6, 6.4_

  - [x] 9.5 ~~Migrate TerminalContainerView to SkinContext~~ — SUPERSEDED
    - `TerminalContainerView` was dead code since April 5 (terminal hierarchy routes through `SplitPaneView` + `MetalCompositor`). Class was deleted entirely in PR #107 rather than migrated.
    - `SurfaceKey.terminalContainerPadding` stays in the enum as a spec-level surface; a future terminal-wrapping view can pick it up without a spec change.
    - _Requirements: 3.6, 6.6, 6.7 (requirements remain valid as spec-level surfaces even with no view painting them today)_

  - [x] 9.6 Migrate SplitPaneView to SkinContext
    - Modify `Sources/Holoscape/Views/SplitPaneView.swift` to accept `skinContext: SkinContext`
    - Delete 2 hardcoded NSColor constants (activeBorder, clearBorder)
    - Resolve divider surface
    - Covered by `SmallViewsSkinContextTests.swift` (PR #104)
    - _Requirements: 3.6, 6.5_

  - [x] 9.7 Wire window.background and window.titleBar surfaces
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` init to resolve `window.background` and `window.titleBar` surfaces
    - Apply fill to `window.backgroundColor` and configure title bar appearance
    - `window.background` shipped (PR #106). `window.titleBar` deferred — the tab bar covers the titlebar band via `tabBar.container` (PR #98 tabs-in-titlebar); a dedicated title-bar accessory view would honor this surface.
    - Covered by `WindowSurfaceResolutionTests.swift`
    - _Requirements: 6.1, 6.2_

  - [x] 9.8 Inject SkinContext from MainWindowController
    - `MainWindowController.init` builds initial `SkinContext` from `SkinEngine` and passes it to every chrome view constructor
    - `MainWindowController.applySkin(_:)` is the entry point for re-injection: takes `[SurfaceKey: SkinContext.ResolvedSurface]?` and re-assigns the 5 chrome view slots. Direct property assignment triggers each view's `didSet` → `refreshFromSkin`, so `applySkin(_:)` does NOT post `.skinDidChange` itself — posting it on top would fire every repaint twice. Callers who need observers outside the controller post it themselves. (PR #106)
    - _Requirements: 3.2, 3.5_

  - [x]* 9.9 Integration test: Chrome view migration
    - Shipped as `Tests/HoloscapeTests/Integration/ChromeViewMigrationTests.swift` (new directory under HoloscapeTests target; SwiftPM auto-discovers the subdirectory)
    - Five tests — one per migrated view (TabBar, Sidebar, InputBox, SessionLauncher, SplitPane) — build a SkinContext with a distinctive per-view color override, assign it, trigger layout, and render the layer tree into an `NSBitmapImageRep` via `CALayer.render(in:)`. Each test also asserts the sampled pixel does NOT equal the built-in default — the "no hardcoded defaults bleed through" guarantee.
    - Uses `CALayer.render(in:)` rather than the spec's `NSView.cacheDisplay(in:to:)`: cacheDisplay produces blank bitmaps for layer-hosted views offscreen without a window (draw(_:in:) never fires, CA's compositor doesn't run). `CALayer.render(in:)` walks the layer tree into a supplied CGContext, which is what the spec actually wants. Rationale captured in the test file header.
    - TerminalContainerView is NOT covered — deleted in PR #107 (task 9.5).
    - _Requirements: 3.6, 4.1-4.5, 5.1-5.7, 6.1-6.7_

- [x] 10. Checkpoint
  - All tests pass (460 pre-existing + 10 new test files = 490+ tests green as of 2026-04-18). Pre-migration regression check is `Tests/HoloscapeTests/Unit/PreMigrationParityTests.swift` — 23 tests freezing every `SkinContext.builtInDefaults` fill against the pre-migration hex extracted from commit `e0aae6f` (merge of PR #102, immediately before chrome view migrations began in PR #103).
  - **Mac-Mini follow-up (deferred):** The laptop-side invariant is "every default fill matches the pre-migration hex value." A full visual regression (actual rendered chrome vs. a pre-migration `e0aae6f` build) still requires running Holoscape on Mac Mini with no skin loaded and diffing screenshots — that's the dogfood pass Task 10 ultimately wants. Pre-migration baseline: checkout `e0aae6f`, build, capture screenshots of each chrome view at default state. Current main: same, no skin loaded. Diff should be pixel-perfect for layout/font/shadow/compositing; color-level parity is guaranteed by PreMigrationParityTests.

- [x] 11. Hot reload
  - [x] 11.0 **Prerequisite — wire v2 apply path through picker + launch**
    - Not originally listed as a subtask; surfaced by the Mac-Mini dogfood after Task 9 and landed as PR #111 before Task 11 proper. `MainWindowController.applySkin(_:)` had zero callers since PR #106; the Appearance Settings picker ran only the v1 apply path. PR #111 adds `SkinEngine.loadComposite(named:)` as the single atomic load entry point, has `MainWindowController` own the shared `SkinEngine` and track `currentFontBundle`, adds `reloadSkin(named:)`, wires init to read `config.appearance.skinName` for launch persistence, and extends `AppearanceSettingsDelegate` with `appearanceSettingsDidSelectSkin(_:)` routed through `AppDelegate` → `MainWindowController.reloadSkin`.
    - Covered by `Tests/HoloscapeTests/Unit/SkinEngineLoadCompositeTests.swift`.

  - [x] 11.1 Implement FSEventStream watcher in SkinEngine
    - `Sources/Holoscape/Services/SkinEngine.swift` gains `startWatching(skinName:)` and `stopWatching()`. `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`, latency 0.05s (FSEvents coalescing; MainWindowController's 200ms debounce is authoritative). Dedicated serial queue `holoscape.skin.watcher`. Callback hops to main via `DispatchQueue.main.async` before touching engine state.
    - Watcher is scoped to the ACTIVE skin's directory only — watching `~/.holoscape/skins/` wholesale would wake the debouncer on every save to every skin. Picker flips via `stopWatching() + startWatching(newName)` inside `reloadSkin`.
    - New `SkinEngineFileWatcherDelegate` protocol; `MainWindowController` conforms. Delegate protocol chosen over closure callback for testability — test spies implement the protocol (`CountingSpy`) without orchestrating real FSEvents.
    - Three-call teardown in `stopWatching` and inline in `deinit` (Stop → Invalidate → Release). `currentStream` is `nonisolated(unsafe)` because Swift 6 nonisolated-deinit can't reach MainActor-isolated state; FSEventStream C APIs are thread-safe so the pointer access is safe.
    - _Requirements: 14.1_

  - [x] 11.2 Implement debounced reload
    - `MainWindowController.skinEngineDidDetectChange(in:)` cancels `pendingReloadWorkItem` and schedules a new 200ms `DispatchWorkItem` via `DispatchQueue.main.asyncAfter`. Matches the canonical pattern from `scheduleSaveState()` elsewhere in the same file. Any user-driven skin switch (via picker) cancels the pending item so stale disk events from a different skin directory can't race with the selection.
    - Reload reuses `reloadSkin(named:)` from PR #111, which does the atomic load via `loadComposite` and keeps the previous `SkinContext` on throw — matches the "keep previous SkinContext active on parse failure" rule.
    - _Requirements: 14.2, 14.4_

  - [x] 11.3 ~~Post SkinDidChange notification~~ — SUPERSEDED
    - Spec wording conflicts with the invariant PR #106 established: `MainWindowController.applySkin(_:)` does NOT post `.skinDidChange` because the direct property assignments it performs already trigger each chrome view's `didSet` → `refreshFromSkin()`. Chrome views ALSO observe `.skinDidChange` directly, so posting on top would fire `refreshFromSkin` twice per reload.
    - Task 11's reload path honors that rule: `reloadSkin` → `applySkin` → property chain → one repaint. No notification post. External observers (none today) can observe the property path or add themselves; chrome views are covered.
    - _Requirements: 14.3 — invariant satisfied via the property chain rather than a notification._

  - [x] 11.4 Release stale image cache
    - Handled by ARC. When `applySkin` assigns a new `SkinContext` to `MainWindowController.skinContext`, the previous context goes out of scope and its `imageCache` dictionary releases with it. Property assignment is the release trigger; no explicit `clearCache()` call needed.
    - _Requirements: 14.5_

  - [x]* 11.5 Integration test: Hot reload flow
    - Shipped as `Tests/HoloscapeTests/Integration/HotReloadTests.swift` — 5 tests covering: write-fires-delegate, stopWatching silences, skin-switch re-points the watcher, Default-name is a safe no-op, missing-skin-dir is a safe no-op. Uses `HOLOSCAPE_CONFIG_DIR` to point at a per-test temp dir. `MainWindowController` debounce is verified indirectly via the Mac-Mini dogfood — standing up a full controller in a unit test is more ceremony than the invariant warrants, and the debounce pattern (`DispatchWorkItem` cancel-and-reschedule) is a direct mirror of `scheduleSaveState()` which the existing 518-test suite already exercises.
    - _Requirements: 14.2, 14.3_

- [x] 12. Reader Mode
  - [x] 12.1 Create `ReaderModeController`
    - Shipped as `Sources/Holoscape/Controllers/ReaderModeController.swift` as `@MainActor final class` conforming to `NSWindowDelegate`.
    - Holds `panel: NSPanel?`, `textView: NSTextView?`, `savedAlpha: CGFloat`, `parentWindow: NSWindow?` (weak). `animationsSuppressed` was not needed — the engine's `suppressAll()` is stateless on the controller side.
    - `activate(for:parentWindow:animationEngine:)`, `dismiss()`, `isActive` getter. `windowWillClose` routes close-button clicks through `dismiss` so alpha restoration runs.
    - _Requirements: 11.1, 11.3_

  - [x] 12.2 Implement scrollback capture with ANSI stripping
    - Uses `ChannelController.lastLines(_ count: Int) -> [String]` (protocol declared at `Sources/Holoscape/Protocols/ChannelController.swift:17`; implemented by `ShellChannelController`, `AgentChannelController`, `SSHChannelController` via SwiftTerm's `terminal.getText`). Calls `channel.lastLines(10_000)`.
    - Stripping extracted to its own value-type helper `Sources/Holoscape/Services/ANSIStripper.swift` for testability. Handles CSI (params 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E), OSC (terminated by BEL or ST), lone two-byte escapes (ESC + 0x40–0x5F), and bare BEL. Order-sensitive: CSI runs first so lone-escape doesn't eat CSI prefixes. Covered by 14 unit tests in `Tests/HoloscapeTests/Unit/ANSIStripperTests.swift` including a realistic prompt+colored-output sample.
    - _Requirements: 11.1, 11.6_

  - [x] 12.3 Implement main window dim
    - `activate` captures `parentWindow.alphaValue` into `savedAlpha`, animates to 0.4 over 200ms via `NSAnimationContext.runAnimationGroup` + `animator().alphaValue`. Matches the codebase's existing constraint-animation pattern. `dismiss` reverses with the saved alpha.
    - `animationEngine?.suppressAll()` is called when an engine is wired. Currently the app's object graph does not own a shared `AnimationEngine` instance (`DensityModeManager.animationEngine` is nil in production — latent since Task 7 landed). Controller accepts `AnimationEngine?` as optional and skips suppression when nil. **Backlog followup**: wire a shared AnimationEngine alongside DensityModeManager so this and the density-mode suppression path both fire.
    - No "resume animations" call on dismiss — `AnimationEngine` re-queues naturally on the next state transition; this is the intended semantics per the spec.
    - _Requirements: 11.2, 11.5_

  - [x] 12.4 Configure NSPanel appearance
    - Panel uses `NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)` — hardcoded, not read from SkinContext. The Reader surface is deliberately skin-neutral.
    - No toolbar. Content is a single `NSScrollView` with an `NSTextView` (`isEditable: false`, `isSelectable: true` so the user can copy/paste, `isRichText: false`, 12pt text-container inset). Pattern directly borrowed from `BugReportDialog.swift:60-66`.
    - `styleMask: [.titled, .closable, .resizable, .nonactivatingPanel]` — draggable via title bar, resizable, with a close button.
    - _Requirements: 11.3, 11.6_

  - [x] 12.5 Maintain focus in main window while panel open
    - `.nonactivatingPanel` style mask plus `panel.isFloatingPanel = true` means the panel floats above the main window without becoming the key window. Main window's first-responder chain (e.g. `inputBox`) stays intact.
    - Panel is shown via `orderFront(nil)` not `makeKeyAndOrderFront(nil)` — no key-window steal.
    - `panel.hidesOnDeactivate = false` so the panel stays visible if Holoscape loses focus (user might tab to another app while reading).
    - _Requirements: 11.4_

  - [x] 12.6 Add menu item for toggle
    - Added to `MainWindowController.setupKeyboardShortcuts()` (not AppDelegate — MainWindowController owns the handler so responder-chain dispatch is reliable, matching existing timestamp/chrome-toggle pattern).
    - Shortcut: `⌘⇧R` (not `⌘R` to avoid clash with common "reload" semantics in dev tools).
    - Handler `@objc func toggleReaderMode()` toggles activate/dismiss; logs and no-ops when no channel is active.
    - _Requirements: 11.7_

  - [ ]* 12.7 Integration test: Reader Mode with active skin
    - Deferred per the `*` optional marker. ANSIStripper has 14 unit tests covering the load-bearing regex correctness; the controller's NSPanel lifecycle is verified via Mac-Mini dogfood. Standing up a full `MainWindowController` + real window in a unit test is heavier than the invariant warrants for this first ship.
    - _Requirements: 11.4, 11.5_

- [x] 13. Reference skin
  - [x] 13.1 Author reference skin (Holoscape Synthwave)
    - Shipped as `Sources/Holoscape/Resources/Skins/HoloscapeSynthwave/skin.json`. Aesthetic diverged from the spec's literal "Holoscape Classic Winamp" name — the synthwave palette (purple gradient window, teal→cyan tab bar, neon pink accents) is distinctive and buildable with procedural gradients + one ninepatch PNG, without real art assets.
    - Surface descriptors cover: window.background (vertical gradient), tabBar.container (horizontal gradient), tabBar.tab.active/idle/permission/normal (colors), sidebar.container (ninepatch image), sidebar.row.selected (color), sidebar.row.indicator (color + state variants), inputBox.container, inputBox.field, sessionLauncher.container, splitPane.divider.
    - State variants wired on `sidebarRowIndicator` for `channelConnectionState` (connecting / disconnected). Agent-state variants would require extending `ReactiveUniformSnapshot` with agent-state uniforms — out of scope for a skin manifest; the variant machinery is demonstrated via the connection-state path.
    - _Requirements: 16.1, 16.2, 16.3, 16.4_

  - [x] 13.2 Ship reference skin assets
    - `assets/sidebar-tile.png` — 32×32 three-band PNG (pink border + dark purple center). Procedurally generated via Python/PIL. Center stretches under ninepatch tile mode.
    - `assets/sidebar-tile.ninepatch.json` — `{"stretchX": [8, 24], "stretchY": [8, 24]}`, carving out the middle 16×16 as the scalable region.
    - **No TTF font.** `FontDescriptor` flows through `SkinContext.convert` into `ResolvedSurface.font`, but no chrome view currently consumes that property — shipping a font would register with CTFontManager and render nothing. Deferred to a future card after chrome-view font consumption lands.
    - _Requirements: 16.2, 16.5_

  - [x] 13.3 Add reference skin to bundle resources
    - `Package.swift` resources gains `.copy("Resources/Skins")` — NOT `.process`. `.process` flattens nested resources (all files end up at the bundle root), which would break both the dedup rule and the ninepatch path lookup. `.copy` preserves the `Skins/<name>/{skin.json, assets/*}` structure.
    - **Discovery path**: `Bundle.module.resourceURL?.appendingPathComponent("Skins")` — NOT `Bundle.main`. SwiftPM resources live under the target's resource bundle (`Holoscape_Holoscape.bundle`), not the app bundle's root Resources. `Bundle.module` is the auto-generated accessor for the Holoscape target's bundle.
    - _Requirements: 16.5_

  - [x] 13.4 Make reference skin selectable from Appearance Settings
    - `SkinEngine.availableSkins()` now walks both `Bundle.module.resourceURL/Skins/` (bundled) and `~/.holoscape/skins/` (user), merging and deduping by name — user skins override bundled ones of the same folder name.
    - `SkinEngine.loadComposite(named:)` resolves through a new private `resolveSkinDir(named:)` that checks user dir first then bundle. Bundled vs user is invisible to callers.
    - **Ninepatch wiring fix (Task 13 prerequisite)**: `SkinContext.convert` gains a `ninepatches: [String: NinepatchSidecar]` parameter. `SkinEngine.loadComposite` walks the loaded images, calls `loadNinepatchSidecar(for:in:)` for each, and passes the resulting map through. Previously the convertFill image branch always passed nil for the sidecar, regardless of what was on disk (there was a TODO comment acknowledging the gap). Covered by `testNinepatchSidecarFlowsThroughConvert` in `BundledSkinTests`.
    - **Picker wiring**: `AppearanceSettingsView`'s popup-menu refresh already calls `skinEngine.availableSkins()` — bundled skins appear automatically in the picker. No separate change to the view was needed.
    - `HOLOSCAPE_BUNDLE_SKINS_DIR` test-override env var added alongside `HOLOSCAPE_CONFIG_DIR` so unit tests can stage fake bundled skins without mocking `Bundle.module`.
    - _Requirements: 16.2_

- [ ] 14. Checkpoint
  - Ensure all tests pass. Verify reference skin loads, renders, and animates correctly.

- [ ] 15. Performance validation
  - [ ]* 15.1 Property test: Zero overhead when off
    - **Property 7: Zero overhead when off**
    - **Validates: Requirements 10.1, 10.3, 15.1, 15.4**
    - Create `Tests/HoloscapePropertyTests/Tests/ZeroOverheadPropertyTests.swift`
    - Start Holoscape with `densityMode == .off`
    - Verify zero SkinContext allocations and zero FSEventStream watchers via memory graph inspection

  - [ ]* 15.2 Integration test: Density mode transitions
    - Create `Tests/HoloscapeTests/Integration/DensityModeTransitionTests.swift`
    - Cycle through full → minimal → off → full
    - Assert each transition completes under 200ms
    - _Requirements: 10.2, 15.2_

  - [ ]* 15.3 Performance test: Asset loading sync and size bounds
    - Create `Tests/HoloscapeTests/Integration/AssetLoadingPerformanceTests.swift`
    - Verify all skin assets load synchronously at skin-apply time
    - Verify total assets for test skin remain under 10MB
    - _Requirements: 15.3_

  - [ ]* 15.4 Performance test: Skin switching latency
    - Create `Tests/HoloscapeTests/Integration/SkinSwitchingLatencyTests.swift`
    - Measure SkinContext rebuild and view re-layout time
    - Assert completes within 200ms
    - _Requirements: 15.5_

- [ ] 16. Checkpoint
  - Ensure all tests pass. Run full test suite. Manual dogfooding: load reference skin, cycle density modes, open/close reader mode, collapse/expand chrome regions.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- `ReactiveUniformSnapshot` (task 4.1) is a cross-card dependency shared with shader card #5945. If that card is descoped, chrome state reactivity (task 3.4 + 4.x) falls back to AppKit notifications as a temporary bridge.
- The AI Skin Builder is NOT in scope for this spec — that is a separate PRD per the design doc's Key Design Decisions.
