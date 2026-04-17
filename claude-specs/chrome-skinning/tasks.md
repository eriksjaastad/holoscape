# Implementation Plan: Chrome Skinning System

## Overview

This plan breaks the Chrome Skinning System into 10 task groups covering: data model extensions, core services (SkinContext, AnimationEngine, ReactiveUniformSnapshot, DensityModeManager, ChromeRegionManager, ReaderModeController), chrome view migrations (6 views), image/font asset pipeline, hot reload, and the built-in reference skin. Tasks follow the project's Swift/AppKit conventions with `Codable, Equatable, Sendable` models and `@MainActor final class` services. Property tests use SwiftCheck; unit and integration tests use XCTest.

The implementation order is: data models → core services → chrome view migrations → asset pipeline → hot reload + reactivity → reference skin. Checkpoints validate incremental progress.

## Tasks

- [ ] 1. Data model extensions
  - [ ] 1.1 Extend `SkinDefinition` with v2 optional fields
    - Modify `Sources/Holoscape/Models/SkinDefinition.swift` to add optional `version`, `name`, `author`, `description` string fields
    - Add optional `surfaces: [String: SurfaceDescriptor]?` dictionary field keyed by SurfaceKey raw value
    - Keep all 10 existing v1 fields unchanged
    - _Requirements: 1.2, 1.3, 1.4_

  - [ ] 1.2 Create `SurfaceKey` enum
    - Create `Sources/Holoscape/Models/SurfaceKey.swift` with an enum `SurfaceKey: String, CaseIterable`
    - Add 23 cases matching the surface catalog from `docs/skins/06-chrome-skinning.md` §6
    - Use dot-separated raw values: `windowBackground = "window.background"`, etc.
    - _Requirements: 3.4_

  - [ ] 1.3 Create descriptor types
    - Create `Sources/Holoscape/Models/SurfaceDescriptor.swift` with `SurfaceDescriptor`, `FillDescriptor`, `BorderDescriptor`, `CornerDescriptor`, `PaddingDescriptor`, `ShadowDescriptor`, `FontDescriptor`, `TextDescriptor`, `AnimationDescriptor`, `CurveDescriptor`, `StateVariant`, `MatchExpression`, `GradientStop`
    - All types `Codable, Equatable, Sendable`
    - `FillDescriptor` is an enum with `color`, `image`, `gradient` cases
    - `CornerDescriptor` is an enum with `uniform` and `asymmetric` cases
    - _Requirements: 2.1, 2.2, 2.4, 2.5_

  - [ ] 1.4 Create `NinepatchSidecar` and `ChromeRegionState` models
    - Create `Sources/Holoscape/Models/NinepatchSidecar.swift` with `stretchX: [Int]` and `stretchY: [Int]` fields
    - Add `ChromeRegionState` struct to `Sources/Holoscape/Models/HoloscapeConfig.swift` alongside existing V3 config types
    - Wire `ChromeRegionState` into `HoloscapeConfig` as an optional field for backward compatibility
    - _Requirements: 2.3, 9.4, 10.5_

  - [ ]* 1.5 Unit tests for v1/v2 codable round-trip
    - Create `Tests/HoloscapeTests/Unit/SkinDefinitionV2Tests.swift`
    - Test v1 manifest decodes without v2 fields, produces nil `surfaces`
    - Test v2 manifest decodes both v1 fields and v2 `surfaces` dictionary
    - Test unknown fields are ignored (forward compat)
    - _Requirements: 1.2, 1.3_

  - [ ]* 1.6 Property test: V1 backward compatibility
    - **Property 1: V1 skin backward compatibility**
    - **Validates: Requirements 1.1, 1.2, 1.3, 1.4**
    - Create `Tests/HoloscapePropertyTests/Tests/V1CompatibilityPropertyTests.swift`
    - Generate random v1 manifests via SwiftCheck, decode, verify output matches legacy SkinEngine.apply output byte-for-byte

  - [ ]* 1.7 Unit tests for SurfaceKey exhaustiveness
    - Create `Tests/HoloscapeTests/Unit/SurfaceKeyTests.swift`
    - Assert `SurfaceKey.allCases.count == 23`
    - Assert every raw value is unique and non-empty
    - _Requirements: 3.4_

  - [ ]* 1.8 Unit tests for malformed manifest handling
    - Create `Tests/HoloscapeTests/Unit/SkinDefinitionErrorTests.swift`
    - Test invalid JSON is rejected with logged error
    - Test malformed v2 surfaces dictionary is gracefully skipped
    - Test fallback to v1 or built-in defaults on parse failure
    - _Requirements: 1.5_

- [ ] 2. Checkpoint
  - Ensure all tests pass. Verify SkinDefinition still loads existing v1 skin.json files without regression.

- [ ] 3. SkinContext and core resolver
  - [ ] 3.1 Create `SkinContext` class with ResolvedSurface
    - Create `Sources/Holoscape/Services/SkinContext.swift` as `@MainActor final class`
    - Add `ResolvedSurface` struct with `fill: ResolvedFill`, `border`, `corner`, `padding`, `shadow`, `font`, `text`, `animation`, `states` fields
    - Add `surfaces: [SurfaceKey: ResolvedSurface]` dictionary
    - Add `reactive: ReactiveUniformSnapshot` reference (will be wired in task 4.1)
    - Add `fontRegistry: [String: CGFont]` and `imageCache: [String: NSImage]` properties
    - _Requirements: 3.1, 3.2, 3.5_

  - [ ] 3.2 Implement `resolve(_:)` and `currentState(for:)` methods
    - `resolve(_ key: SurfaceKey) -> ResolvedSurface` returns resolved surface or built-in default
    - `currentState(for key: SurfaceKey) -> ResolvedSurface` evaluates state variants against current snapshot and returns merged result
    - Built-in defaults match the existing hardcoded colors per view
    - _Requirements: 3.3_

  - [ ] 3.3 Implement `applyFill(to:from:)` and `applyBorderAndCorner(to:from:)`
    - `applyFill(to layer: CALayer, from resolved: ResolvedSurface)` — handles color, image, gradient variants
    - For gradient fills, insert a `CAGradientLayer` sublayer into the target layer
    - For image fills with ninepatch, set `layer.contentsCenter` from the sidecar
    - `applyBorderAndCorner` sets `borderColor`, `borderWidth`, `cornerRadius`, shadow properties
    - _Requirements: 2.6, 7.2_

  - [ ] 3.4 Implement match expression evaluator
    - Add private `evaluateMatch(_ expr: MatchExpression) -> Bool` method
    - Support match keys: `agentState`, `previousAgentState`, `commandState`, `previousCommandState`, `lastCommandExitCode`, `channelId`, `channelIsActive`, `channelUnread`, `notificationKind`, `timeSince`
    - Support operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`; bare scalar is `$eq` shorthand
    - Multi-key matches combined with logical AND
    - Unknown keys/operators logged and skipped (no crash)
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

  - [ ]* 3.5 Property test: State variant determinism
    - **Property 5: State variant determinism**
    - **Validates: Requirements 12.1, 12.2, 12.4, 12.5, 12.6**
    - Create `Tests/HoloscapePropertyTests/Tests/StateDeterminismPropertyTests.swift`
    - Generate random (surface, snapshot) pairs; evaluate 10 times; verify identical results

  - [ ]* 3.6 Property test: Match operator totality
    - **Property 6: Match operator totality**
    - **Validates: Requirement 12.3**
    - Create `Tests/HoloscapePropertyTests/Tests/OperatorTotalityPropertyTests.swift`
    - Verify no operator throws, no nil returns, no crashes on random inputs

  - [ ]* 3.7 Unit tests for SkinContext resolution
    - Create `Tests/HoloscapeTests/Unit/SkinContextResolutionTests.swift`
    - Test default fallback when surface not in manifest
    - Test v1→v2 merge semantics (child overrides parent)
    - Test state variant evaluation with last-match-wins CSS cascade semantics
    - _Requirements: 3.3, 12.4_

  - [ ]* 3.8 Property test: State snapshot consistency
    - **Property 15: State snapshot consistency**
    - **Validates: Requirements 12.1, 12.2, 12.5, 12.6**
    - Create `Tests/HoloscapePropertyTests/Tests/StateSnapshotConsistencyPropertyTests.swift`
    - Verify chrome layer and shader layer read identical snapshot values on state transition
    - Verify all specified match keys are supported and evaluate deterministically

- [ ] 4. ReactiveUniformSnapshot
  - [ ] 4.1 Create `ReactiveUniformSnapshot` with atomic fields
    - Create `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift` as `final class ReactiveUniformSnapshot: @unchecked Sendable`
    - Use atomic-backed properties for `agentState`, `previousAgentState`, `commandState`, `channelUnread`, `notificationKind` (Int32)
    - Use atomic-backed properties for `timeAgentStateChange`, `timeLastOutput`, `timeCommandStart`, `timeCommandEnd`, `timeLastNotification` (Double via bitcast)
    - Match the field set from `docs/skins/05-reactive-uniforms.md` §5
    - _Requirements: 12.6_

  - [ ] 4.2 Implement `stampTransition` method
    - Enum `TimestampField` with cases for each timestamp field
    - `stampTransition(_ field: TimestampField)` writes `CFAbsoluteTimeGetCurrent()` to the corresponding field atomically
    - _Requirements: 12.5, 12.6_

  - [ ]* 4.3 Unit tests for atomic reads across threads
    - Create `Tests/HoloscapeTests/Unit/ReactiveUniformSnapshotTests.swift`
    - Test concurrent writes from multiple threads produce observable atomic writes
    - Test timestamp stamping is monotonic per field
    - _Requirements: 12.6_

- [ ] 5. AnimationEngine
  - [ ] 5.1 Create `AnimationEngine` class
    - Create `Sources/Holoscape/Services/AnimationEngine.swift` as `@MainActor final class`
    - Add `displayLink: CADisplayLink?` property (initially nil)
    - Add `activeAnimations: [AnimationID: AnimationState]` dictionary
    - `animateSurface(_:to:on:with:)` method queues animation and starts display link if needed
    - _Requirements: 13.1, 13.3_

  - [ ] 5.2 Implement curve translation
    - Map curve string values to `CAMediaTimingFunction` instances: `linear`, `easeIn`, `easeOut`, `easeInOut`
    - For `spring`, use `CASpringAnimation` instead of `CABasicAnimation`
    - Per-property overrides (fill/corner) take precedence over default curve
    - _Requirements: 13.2, 13.4_

  - [ ] 5.3 Implement display link lifecycle
    - `startDisplayLinkIfNeeded()` — creates and starts if any active animations
    - `stopDisplayLinkIfIdle()` — invalidates and nils when no active animations remain
    - `suppressAll()` — immediately completes all animations for density mode transition
    - _Requirements: 13.3, 13.5_

  - [ ]* 5.4 Unit tests for AnimationEngine lifecycle
    - Create `Tests/HoloscapeTests/Unit/AnimationEngineTests.swift`
    - Test display link starts when first animation queued
    - Test display link stops when all animations complete
    - Test suppression in minimal mode applies final state instantly
    - _Requirements: 13.3, 13.5_

  - [ ]* 5.5 Property test: Display link idleness
    - **Property 8: Display link idleness**
    - **Validates: Requirements 13.3, 15.4**
    - Create `Tests/HoloscapePropertyTests/Tests/DisplayLinkIdlenessPropertyTests.swift`
    - Verify CADisplayLink is not running when no animation is active

- [ ] 6. Checkpoint
  - Ensure all tests pass. Verify SkinContext, ReactiveUniformSnapshot, and AnimationEngine compile and interact correctly via unit tests.

- [ ] 7. Density and region management
  - [ ] 7.1 Create `DensityModeManager`
    - Create `Sources/Holoscape/Services/DensityModeManager.swift` as `@MainActor final class`
    - `Mode` enum with `.full`, `.minimal`, `.off` cases, Codable
    - `setMode(_ newMode: Mode)` triggers 200ms transition
    - `isSkinActive()`, `shouldRenderImages()`, `shouldAnimate()` query methods
    - Persist mode to `HoloscapeConfig.appearance.densityMode` (add field)
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_

  - [ ]* 7.1b Property test: Animation suppression leakage
    - **Property 16: No animation suppression leakage**
    - **Validates: Requirements 13.5, 13.1, 13.2, 13.4**
    - Create `Tests/HoloscapePropertyTests/Tests/AnimationSuppressionLeakagePropertyTests.swift`
    - Verify animations suppressed in Minimal/Off do not replay on transition to Full

  - [ ] 7.2 Wire DensityModeManager into AnimationEngine and SkinEngine
    - Modify `AnimationEngine` to query `densityModeManager.shouldAnimate()` before starting animations
    - Modify `SkinEngine` to short-circuit loading when mode is `.off`
    - Modify `SkinContext` to skip image fills when mode is `.minimal`
    - _Requirements: 10.3, 10.4_

  - [ ] 7.3 Create `ChromeRegionManager`
    - Create `Sources/Holoscape/Controllers/ChromeRegionManager.swift` as `@MainActor final class`
    - `Region` enum with `.top`, `.right`, `.bottom`, `.left` cases
    - `collapsedRegions: Set<Region>` property
    - `toggleRegion`, `collapseRegion(animated:)`, `expandRegion(animated:)` methods
    - _Requirements: 9.1, 9.2, 9.3_

  - [ ] 7.4 Implement region collapse animation
    - 200ms ease-out slide using `NSLayoutConstraint` animation or `NSAnimationContext`
    - Terminal viewport expands to fill freed space via constraint priority adjustment
    - _Requirements: 9.2, 9.3_

  - [ ] 7.5 Persist region state to HoloscapeConfig
    - Call `persistState()` on region toggle
    - Call `restoreState()` on app launch from `MainWindowController.init`
    - _Requirements: 9.4, 9.5_

  - [ ] 7.6 Add View menu items for region toggle
    - Modify `Sources/Holoscape/AppDelegate.swift` to add "Top Chrome", "Right Chrome", "Bottom Chrome", "Left Chrome" items under View menu
    - Each item calls `ChromeRegionManager.toggleRegion`
    - _Requirements: 9.6_

  - [ ]* 7.7 Unit tests for ChromeRegionManager
    - Create `Tests/HoloscapeTests/Unit/ChromeRegionManagerTests.swift`
    - Test collapse/expand, persistence round-trip, animation duration
    - _Requirements: 9.2, 9.3, 9.4_

  - [ ]* 7.8 Unit tests for DensityModeManager
    - Create `Tests/HoloscapeTests/Unit/DensityModeManagerTests.swift`
    - Test mode transitions complete under 200ms
    - Test animation suppression in minimal/off modes
    - _Requirements: 10.2, 10.4_

- [ ] 8. Asset pipeline (images and fonts)
  - [ ] 8.1 Implement image loading in SkinEngine
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to add `loadImages(from:manifest:) -> [String: NSImage]` method
    - Load all referenced PNG images via `NSImage(contentsOfFile:)` at skin-apply time
    - Cache per-skin in SkinContext
    - Release on skin unload
    - _Requirements: 1.7, 7.1, 7.4_

  - [ ] 8.2 Implement ninepatch sidecar loading
    - Add `loadNinepatchSidecar(for imagePath:) -> NinepatchSidecar?` to SkinEngine
    - For image at `assets/tab-bg.png`, look for `assets/tab-bg.ninepatch.json`
    - When sidecar exists, auto-apply ninepatch tile mode via `CALayer.contentsCenter`
    - _Requirements: 2.3, 7.2_

  - [ ] 8.3 Implement asset path validation
    - Add `validateAssetPath(_ path: String) throws` to SkinEngine
    - Reject paths containing `..`, absolute paths, `http://`, `https://` URLs
    - Throw before any file system access
    - _Requirements: 1.6_

  - [ ] 8.4 Implement font loading and registration
    - Modify `SkinEngine.registerFonts(from fontDirectory:)` to scan `assets/fonts/` for `.otf` and `.ttf` files
    - Register via `CTFontManagerRegisterFontsForURL` with process scope
    - Return `[String: CGFont]` map
    - On skin unload, call `CTFontManagerUnregisterFontsForURL`
    - Fall back to system default on load failure
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

  - [ ]* 8.4b Property test: Font registration symmetry
    - **Property 9: Font registration symmetry**
    - **Validates: Requirement 8.3**
    - Create `Tests/HoloscapePropertyTests/Tests/FontRegistrationSymmetryPropertyTests.swift`
    - Verify fonts deregistered on skin unload match exactly those that were registered

  - [ ] 8.5 Wire backing scale factor to image layers
    - In `SkinContext.applyFill(to:from:)`, set `layer.contentsScale = layer.window?.backingScaleFactor ?? 2.0`
    - _Requirements: 7.3_

  - [ ]* 8.6 Property test: Asset path sandboxing
    - **Property 2: Asset path sandboxing**
    - **Validates: Requirement 1.6**
    - Create `Tests/HoloscapePropertyTests/Tests/PathSandboxingPropertyTests.swift`
    - Generate random unsafe paths; verify validator rejects every pattern

  - [ ]* 8.7 Unit tests for ninepatch loading
    - Create `Tests/HoloscapeTests/Unit/NinepatchSidecarTests.swift`
    - Test valid sidecar loads correctly
    - Test invalid ranges (stretchX[0] >= stretchX[1]) rejected
    - _Requirements: 2.3_

- [ ] 9. Chrome view migrations
  - [ ] 9.1 Migrate TabBarView to SkinContext
    - Modify `Sources/Holoscape/Views/TabBarView.swift` to accept `skinContext: SkinContext` in init
    - Delete 9 hardcoded NSColor constants
    - Resolve container, active tab, idle tab, permission tab, normal tab, unread marker surfaces via `skinContext.currentState(for:)`
    - Apply via `skinContext.applyFill(to:from:)` in `layout()` override
    - Observe `SkinDidChange` notification to re-layout
    - _Requirements: 3.6, 4.1, 4.2, 4.3, 4.4, 4.5_

  - [ ] 9.2 Migrate SidebarView to SkinContext
    - Modify `Sources/Holoscape/Views/SidebarView.swift` to accept `skinContext: SkinContext`
    - Delete 18 hardcoded NSColor constants across `SidebarView` and nested `SidebarTabEntry`
    - Resolve container, row states (normal/selected/hover), indicator, section header surfaces
    - Preserve scroll behavior via `NSScrollView` (no change)
    - _Requirements: 3.6, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_

  - [ ] 9.3 Migrate InputBoxView to SkinContext
    - Modify `Sources/Holoscape/Views/InputBoxView.swift` to accept `skinContext: SkinContext`
    - Delete 3 hardcoded NSColor constants
    - Resolve container, field, placeholder surfaces
    - _Requirements: 3.6, 6.3_

  - [ ] 9.4 Migrate SessionLauncherView to SkinContext
    - Modify `Sources/Holoscape/Views/SessionLauncherView.swift` to accept `skinContext: SkinContext`
    - Delete 1 hardcoded NSColor constant
    - Resolve container and row surfaces
    - _Requirements: 3.6, 6.4_

  - [ ] 9.5 Migrate TerminalContainerView to SkinContext
    - Modify `Sources/Holoscape/Views/TerminalContainerView.swift` to accept `skinContext: SkinContext`
    - Delete 1 hardcoded NSColor constant
    - Resolve padding surface
    - _Requirements: 3.6, 6.6, 6.7_

  - [ ] 9.6 Migrate SplitPaneView to SkinContext
    - Modify `Sources/Holoscape/Views/SplitPaneView.swift` to accept `skinContext: SkinContext`
    - Delete 2 hardcoded NSColor constants (activeBorder, clearBorder)
    - Resolve divider surface
    - _Requirements: 3.6, 6.5_

  - [ ] 9.7 Wire window.background and window.titleBar surfaces
    - Modify `Sources/Holoscape/Controllers/MainWindowController.swift` init to resolve `window.background` and `window.titleBar` surfaces
    - Apply fill to `window.backgroundColor` and configure title bar appearance
    - _Requirements: 6.1, 6.2_

  - [ ] 9.8 Inject SkinContext from MainWindowController
    - Modify `MainWindowController.init` to build initial `SkinContext` from `SkinEngine`
    - Pass `skinContext` to every chrome view constructor
    - Observe `SkinDidChange` to rebuild context and re-inject
    - _Requirements: 3.2, 3.5_

  - [ ]* 9.9 Integration test: Chrome view migration
    - Create `Tests/HoloscapeTests/Integration/ChromeViewMigrationTests.swift`
    - Load a test skin that overrides every chrome surface
    - Render each view offscreen via `NSView.cacheDisplay(in:to:)`
    - Sample pixel colors via `NSBitmapImageRep`; assert no hardcoded defaults bleed through
    - _Requirements: 3.6, 4.1-4.5, 5.1-5.7, 6.1-6.7_

- [ ] 10. Checkpoint
  - Ensure all tests pass. Verify Holoscape renders identically to pre-migration build when no skin loaded (regression check).

- [ ] 11. Hot reload
  - [ ] 11.1 Implement FSEventStream watcher in SkinEngine
    - Modify `Sources/Holoscape/Services/SkinEngine.swift` to add `startWatching(skinDirectory:)` and `stopWatching()` methods
    - Use `FSEventStreamCreate` with callback on file changes
    - _Requirements: 14.1_

  - [ ] 11.2 Implement debounced reload
    - On file change event, start 200ms debounce timer
    - On timer fire, re-parse `skin.json`, rebuild SkinContext, re-register fonts (deregister old, register new)
    - If parse fails, log error and keep previous SkinContext active
    - _Requirements: 14.2, 14.4_

  - [ ] 11.3 Post SkinDidChange notification
    - After successful reload, post `NotificationCenter.default.post(name: .skinDidChange, object: nil)`
    - All chrome views observe and call `layout()`
    - _Requirements: 14.3_

  - [ ] 11.4 Release stale image cache
    - On reload, release `imageCache` from previous SkinContext
    - Load new images from updated manifest
    - _Requirements: 14.5_

  - [ ]* 11.5 Integration test: Hot reload flow
    - Create `Tests/HoloscapeTests/Integration/HotReloadTests.swift`
    - Load test skin, modify `skin.json`, verify SkinContext rebuilt within 500ms
    - _Requirements: 14.2, 14.3_

- [ ] 12. Reader Mode
  - [ ] 12.1 Create `ReaderModeController`
    - Create `Sources/Holoscape/Controllers/ReaderModeController.swift` as `@MainActor final class`
    - Add `panel: NSPanel?`, `savedAlpha`, `animationsSuppressed` properties
    - `activate(for channel: Channel)`, `dismiss()`, `isActive` getter
    - _Requirements: 11.1, 11.3_

  - [ ] 12.2 Implement scrollback capture with ANSI stripping
    - `captureScrollback(from channel:) -> String` reads channel's scrollback buffer
    - Strip ANSI escape codes via regex (CSI sequences, SGR codes)
    - Return plain text
    - _Requirements: 11.1, 11.6_

  - [ ] 12.3 Implement main window dim
    - `dimMainWindow()` saves current alpha, sets to 0.4 via animation
    - Calls `AnimationEngine.suppressAll()` to pause skin animations
    - `restoreMainWindow()` restores alpha and resumes animations
    - _Requirements: 11.2, 11.5_

  - [ ] 12.4 Configure NSPanel appearance
    - Panel uses SF Mono at 14pt regardless of active skin
    - No toolbar, no navigation, scrollable NSScrollView with NSTextView
    - Panel is draggable and resizable
    - _Requirements: 11.3, 11.6_

  - [ ] 12.5 Maintain focus in main window while panel open
    - Panel uses `NSPanel.StyleMask` without `.titled` focus stealing
    - Console input focus stays in MainWindowController's first responder chain
    - _Requirements: 11.4_

  - [ ] 12.6 Add menu item for toggle
    - Modify `Sources/Holoscape/AppDelegate.swift` to add "Reader Mode" under View menu
    - Calls `ReaderModeController.activate` / `dismiss`
    - _Requirements: 11.7_

  - [ ]* 12.7 Integration test: Reader Mode with active skin
    - Create `Tests/HoloscapeTests/Integration/ReaderModeIntegrationTests.swift`
    - Load skin, activate reader mode, verify main window dims within 100ms and scrollback appears
    - Dismiss and verify restoration
    - _Requirements: 11.4, 11.5_

- [ ] 13. Reference skin
  - [ ] 13.1 Author `Holoscape Classic Winamp` reference skin
    - Create `Sources/Holoscape/Resources/Skins/HoloscapeClassicWinamp/skin.json` with v2 manifest
    - Include surface descriptors for tab bar (gradient + image), sidebar (ninepatch), input box, window background
    - Include state variants for agent state (thinking, error)
    - _Requirements: 16.1, 16.2, 16.3, 16.4_

  - [ ] 13.2 Ship reference skin assets
    - Create `Sources/Holoscape/Resources/Skins/HoloscapeClassicWinamp/assets/tab-active.png` (@2x)
    - Create `Sources/Holoscape/Resources/Skins/HoloscapeClassicWinamp/assets/sidebar-bg.png` with `.ninepatch.json` sidecar
    - Create `Sources/Holoscape/Resources/Skins/HoloscapeClassicWinamp/assets/fonts/Px437_IBM_VGA_8x16.ttf` (open source pixel font)
    - _Requirements: 16.2, 16.5_

  - [ ] 13.3 Add reference skin to bundle resources
    - Modify `Package.swift` to add `.process("Resources/Skins")` to Holoscape target resources
    - Ensure SkinEngine discovers the bundled skin at launch
    - _Requirements: 16.5_

  - [ ] 13.4 Make reference skin selectable from Appearance Settings
    - Modify `Sources/Holoscape/Views/AppearanceSettingsView.swift` to list bundled skins alongside `~/.holoscape/skins/*`
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
