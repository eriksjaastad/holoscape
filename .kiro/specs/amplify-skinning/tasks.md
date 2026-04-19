# Implementation Plan: Amplify Skinning

## Overview

Amplify extends Holoscape's chrome-skinning system to Winamp-class skinning with shaped windows, sprite art, drag regions, font consumption, border/corner/shadow rendering, and `.wamp` bundle format. Implementation proceeds incrementally: data model changes first, then engine/context extensions, then chrome view consumption, then bundle format, then reference skins, then property tests.

## Tasks

- [ ] 1. Extend data models with Amplify v3 types
  - [ ] 1.1 Add WindowShapeDescriptor, Polygon, Point, and DragRegionDescriptor model types
    - Create `WindowShapeDescriptor` struct with `Kind` enum (`.polygons`), optional `polygons` array
    - Create `Polygon` struct with `points: [Point]` array
    - Create `Point` struct with `x: Double, y: Double`
    - Create `DragRegionDescriptor` struct with `polygons: [Polygon]`
    - All types must be `Codable, Equatable, Sendable`
    - Add to `Sources/Holoscape/Models/` (new file or extend existing)
    - _Requirements: 12.1, 12.2, 12.3, 12.4_

  - [ ] 1.2 Add SpriteDescriptor and SpriteCell model types
    - Create `SpriteDescriptor` struct with `cellWidth: Int`, `cellHeight: Int`, `rows: Int`, `cols: Int`, `stateMap: [String: SpriteCell]`
    - Create `SpriteCell` struct with `row: Int`, `col: Int`
    - All types must be `Codable, Equatable, Sendable`
    - _Requirements: 13.1, 13.2, 13.3_

  - [ ] 1.3 Extend FillDescriptor.image case with optional sprite parameter
    - Change `.image(path: String, tile: TileMode)` to `.image(path: String, tile: TileMode, sprite: SpriteDescriptor?)`
    - Update `init(from:)` and `encode(to:)` to handle optional `sprite` field
    - Existing image fills decode with `sprite: nil` (backward compatible)
    - Update all existing call sites that construct or pattern-match `.image`
    - _Requirements: 13.1, 13.4, 13.5_

  - [ ] 1.4 Extend SkinDefinition with v3 optional fields
    - Add `var windowShape: WindowShapeDescriptor?` to `SkinDefinition`
    - Add `var dragRegions: [DragRegionDescriptor]?` to `SkinDefinition`
    - Both fields are optional with nil defaults — existing v1/v2 manifests decode unchanged
    - _Requirements: 9.3, 12.1, 12.3_

  - [ ] 1.5 Expand SurfaceKey enum with new Amplify cases
    - Add `tabBarTabHover`, `tabBarTabPressed` cases
    - Add `sidebarRowPressed` case
    - Add `sessionLauncherButtonNormal`, `sessionLauncherButtonHover`, `sessionLauncherButtonPressed` cases
    - Add `readerPanelTitleBar`, `readerPanelBackground`, `readerPanelCloseButtonNormal`, `readerPanelCloseButtonHover`, `readerPanelCloseButtonPressed` cases
    - _Requirements: 14.1, 14.2, 14.3, 14.4_

  - [ ] 1.6 Extend LoadedSkin with windowShape and dragRegions fields
    - Add `let windowShape: WindowShapeDescriptor?` to `LoadedSkin`
    - Add `let dragRegions: [DragRegionDescriptor]?` to `LoadedSkin`
    - Update `LoadedSkin.defaults` sentinel to include nil for both fields
    - Update all existing `LoadedSkin` construction sites
    - _Requirements: 1.1, 4.1_

- [ ] 2. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 3. Implement SpriteResolver and PolygonHitTester pure-function components
  - [ ] 3.1 Implement SpriteResolver
    - Create `SpriteResolver` struct in `Sources/Holoscape/Services/`
    - Implement `static func cellRect(for state: String, in sprite: SpriteDescriptor) -> CGRect`
    - Fallback chain: requested state → `"normal"` → cell at (0, 0)
    - Pure function, no side effects
    - _Requirements: 2.2, 2.3, 2.4_

  - [ ]* 3.2 Write property test for SpriteResolver (Property 2: Sprite Cell Slicing Correctness)
    - **Property 2: Sprite Cell Slicing Correctness**
    - **Validates: Requirements 2.2, 2.3, 2.4**
    - Create `Tests/HoloscapePropertyTests/SpriteCellSlicingPropertyTests.swift`
    - Generate random SpriteDescriptors (positive cellWidth/cellHeight/rows/cols) and state names
    - Verify cellRect matches stateMap entry, falls back to "normal", then to (0,0)

  - [ ] 3.3 Implement PolygonHitTester
    - Create `PolygonHitTester` struct in `Sources/Holoscape/Services/`
    - Implement `static func contains(point: CGPoint, in polygons: [Polygon]) -> Bool` using ray-casting algorithm
    - Implement `static func boundingBox(of polygon: Polygon) -> CGRect`
    - O(V) per polygon where V = vertex count
    - _Requirements: 3.1, 3.3_

  - [ ]* 3.4 Write property test for PolygonHitTester (Property 3: Point-in-Polygon Correctness)
    - **Property 3: Point-in-Polygon Correctness**
    - **Validates: Requirements 3.1, 3.3**
    - Create `Tests/HoloscapePropertyTests/PolygonHitTestPropertyTests.swift`
    - Generate random convex polygons and test points
    - Verify centroid is always inside; points far outside are always outside

- [ ] 4. Extend SkinEngine with Amplify validation and loading
  - [ ] 4.1 Add polygon bounds validation to SkinEngine
    - Implement `validatePolygonBounds(_:contentSize:)` — rejects polygon sets entirely outside bounds
    - Accept polygon sets where at least one vertex lies inside the bounding rectangle
    - _Requirements: 1.4_

  - [ ]* 4.2 Write property test for polygon bounds validation (Property 4: Polygon Bounds Validation)
    - **Property 4: Polygon Bounds Validation**
    - **Validates: Requirements 1.4**
    - Create `Tests/HoloscapePropertyTests/PolygonBoundsValidationPropertyTests.swift`
    - Generate random polygon sets and bounding rects
    - Verify rejection when all vertices outside, acceptance when at least one inside

  - [ ] 4.3 Add drag region minimum size warning to SkinEngine
    - Implement `warnSmallDragRegions(_:)` — logs warning for drag regions with bounding box < 44×44 pt
    - No warning for regions ≥ 44×44 pt
    - _Requirements: 4.6_

  - [ ]* 4.4 Write property test for drag region size warning (Property 5: Drag Region Minimum Size Warning)
    - **Property 5: Drag Region Minimum Size Warning**
    - **Validates: Requirements 4.6**
    - Create `Tests/HoloscapePropertyTests/DragRegionSizePropertyTests.swift`
    - Generate random polygons with varying bounding boxes
    - Verify warning produced for < 44×44, no warning for ≥ 44×44

  - [ ] 4.5 Extend SkinEngine.loadComposite to parse windowShape and dragRegions
    - Parse `windowShape` from manifest and validate polygon bounds
    - Parse `dragRegions` from manifest and warn on small regions
    - Thread both through to `LoadedSkin`
    - Handle unknown `windowShape.kind` values gracefully (log + ignore)
    - _Requirements: 1.1, 4.1, 12.5, 12.6_

  - [ ] 4.6 Extend SkinEngine.loadImages to handle sprite descriptors
    - When loading images, detect sprite metadata in FillDescriptor
    - Sprite images load through the same pipeline as regular images
    - Log warning when sprite stateMap has no "normal" entry
    - _Requirements: 2.1, 2.9_

- [ ] 5. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 6. Extend SkinContext with sprite, shadow, and font resolution
  - [ ] 6.1 Extend SkinContext.ResolvedFill with sprite case
    - Add `.sprite(NSImage, SpriteDescriptor, NinepatchSidecar?)` case to `ResolvedFill`
    - Update `convertFill` to produce `.sprite` when a FillDescriptor.image has a non-nil sprite
    - _Requirements: 2.2_

  - [ ] 6.2 Extend SkinContext.applyFill to handle sprite-sheet slicing
    - When fill is `.sprite`, use `SpriteResolver.cellRect` to slice the correct cell
    - Set the cropped sub-image as the CALayer's contents via `layer.contentsRect`
    - Fall back to full image if sprite resolution fails
    - _Requirements: 2.2, 2.3_

  - [ ] 6.3 Add SkinContext.applyShadow method
    - Implement `applyShadow(to: CALayer, from: ResolvedSurface)` — applies shadow color, opacity, blur, offset
    - When shadow is nil, set `layer.shadowOpacity = 0`
    - _Requirements: 6.3_

  - [ ]* 6.4 Write property test for border/corner/shadow application (Property 6)
    - **Property 6: Border, Corner, and Shadow Layer Application**
    - **Validates: Requirements 6.1, 6.2, 6.3**
    - Create `Tests/HoloscapePropertyTests/BorderCornerShadowPropertyTests.swift`
    - Generate random ResolvedBorder/Corner/Shadow values
    - Verify CALayer properties match resolved descriptors after application

  - [ ] 6.5 Add SkinContext.resolvedFont method
    - Implement `resolvedFont(for: SurfaceKey) -> NSFont?` — resolves font from skin font registry
    - Fall back to system monospaced font when skin font not found
    - _Requirements: 5.1, 5.5_

  - [ ] 6.6 Add defaultSurface entries for all new SurfaceKey cases
    - Extend `SkinContext.defaultSurface(for:)` to return sensible defaults for all new Amplify keys
    - Tab hover/pressed: transparent fill, white text
    - Sidebar pressed: transparent fill, light gray text
    - Session launcher button states: clear fill, white text
    - Reader panel keys: dark background fill, white text
    - _Requirements: 14.5_

  - [ ]* 6.7 Write property test for default surface completeness (Property 9)
    - **Property 9: Default Surface Completeness**
    - **Validates: Requirements 14.5**
    - Create `Tests/HoloscapePropertyTests/DefaultSurfaceCompletenessPropertyTests.swift`
    - Iterate all `SurfaceKey.allCases`
    - Verify each returns a valid ResolvedSurface with non-nil fill, valid text color, corner radius ≥ 0

- [ ] 7. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 8. Wire border/corner/shadow and font consumption into chrome views
  - [ ] 8.1 Wire border/corner/shadow into TabBarView.refreshFromSkin
    - Call `skinContext.applyBorderAndCorner(to:from:)` on the container layer
    - Call `skinContext.applyShadow(to:from:)` on the container layer
    - Apply border/corner/shadow to individual tab button layers
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [ ] 8.2 Wire border/corner/shadow into SidebarView and SidebarTabEntry.refreshFromSkin
    - Call `applyBorderAndCorner` and `applyShadow` on sidebar container and row layers
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [ ] 8.3 Wire border/corner/shadow into InputBoxView.refreshFromSkin
    - Call `applyBorderAndCorner` and `applyShadow` on the input box's backing layer
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [ ] 8.4 Wire border/corner/shadow into SessionLauncherView.refreshFromSkin
    - Call `applyBorderAndCorner` and `applyShadow` on the launcher container layer
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

  - [ ] 8.5 Wire font consumption into TabBarView
    - Resolve font via `skinContext.resolvedFont(for: .tabBarTabActive)` (or per-state key)
    - Apply to tab button labels in `refreshFromSkin()`
    - Fall back to system monospaced font when nil
    - _Requirements: 5.2_

  - [ ] 8.6 Wire font consumption into SidebarView / SidebarTabEntry
    - Resolve font via `skinContext.resolvedFont(for: .sidebarRowNormal)`
    - Apply to label fields in `refreshFromSkin()` / `configureLast()`
    - Fall back to system monospaced font when nil
    - _Requirements: 5.3_

  - [ ] 8.7 Wire font consumption into InputBoxView
    - Resolve font via `skinContext.resolvedFont(for: .inputBoxField)`
    - Apply to the text view's font in `refreshFromSkin()`
    - Fall back to system monospaced font when nil
    - _Requirements: 5.4_

- [ ] 9. Wire sprite-sheet state transitions into chrome views
  - [ ] 9.1 Add NSTrackingArea hover/pressed handling to TabBarView tab buttons
    - Install NSTrackingArea on each tab button for mouseEntered/mouseExited
    - On hover: re-resolve sprite fill with "hover" state
    - On mouseDown: re-resolve with "pressed" state
    - On mouseUp/mouseExited: re-resolve with "normal" state
    - Density `.minimal` substitutes color fallback for sprite fills
    - _Requirements: 2.5, 2.6, 2.7, 2.8_

  - [ ] 9.2 Add NSTrackingArea hover/pressed handling to SidebarTabEntry
    - Install NSTrackingArea for hover detection
    - Re-resolve sprite fill on state changes
    - _Requirements: 2.5, 2.6, 2.7_

  - [ ] 9.3 Add NSTrackingArea hover/pressed handling to SessionLauncherView buttons
    - Wire hover/pressed sprite state transitions for launcher buttons
    - Use `sessionLauncherButtonNormal/Hover/Pressed` surface keys
    - _Requirements: 2.5, 2.6, 2.7_

- [ ] 10. Implement shaped window rendering in MainWindowController
  - [ ] 10.1 Implement applyWindowShape in MainWindowController
    - Switch NSWindow to `.borderless`, `isOpaque = false`, `backgroundColor = .clear`
    - Build `CGPath` from polygon vertices and apply as `CAShapeLayer` mask on `contentView.layer`
    - Preserve window frame origin and content across style-mask transition
    - Gate behind `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` environment variable
    - _Requirements: 1.2, 1.5, 18.1, 18.2, 18.3_

  - [ ] 10.2 Implement ShapedContentView with hitTest override
    - Create `ShapedContentView` NSView subclass overriding `hitTest(_:)`
    - Return nil for points outside the window-shape polygon region (using PolygonHitTester)
    - Default rectangular hit-test when no windowShape declared
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [ ] 10.3 Implement drag region handling in MainWindowController
    - Install NSTrackingAreas for declared drag region polygons
    - On mouseDown inside drag region: call `window.performDrag(with: event)`
    - On hover: set cursor to `NSCursor.openHand`; on mouseDown: `NSCursor.closedHand`
    - Fallback: `window.isMovableByWindowBackground = true` when borderless + no drag regions
    - Ignore dragRegions when window is titled (rectangular, has system title bar)
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.7_

  - [ ] 10.4 Wire density mode and accessibility into shaped window rendering
    - Density `.off`: bypass shaped-window rendering, retain titled rectangular NSWindow
    - Density `.minimal`: apply shape mask but skip sprite/animation features
    - Reduce Motion: skip fade animation during shape transitions
    - Reduce Transparency: render masked regions as opaque system-gray
    - _Requirements: 1.6, 1.7, 1.8, 16.1_

  - [ ]* 10.5 Write property test for accessibility preservation (Property 12)
    - **Property 12: Accessibility Labels Preserved Across Skin Changes**
    - **Validates: Requirements 16.2**
    - Create `Tests/HoloscapePropertyTests/AccessibilityPreservationPropertyTests.swift`
    - Apply random skin configurations to chrome views
    - Verify accessibility identifier, role, and title remain unchanged

- [ ] 11. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 12. Implement WampLoader and `.wamp` bundle support
  - [ ] 12.1 Add ZIPFoundation dependency to Package.swift
    - Add `.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")` to dependencies
    - Add `"ZIPFoundation"` to the Holoscape target's dependencies
    - _Requirements: 7.7_

  - [ ] 12.2 Implement WampLoader component
    - Create `WampLoader` class in `Sources/Holoscape/Services/`
    - Implement `extract(_ wampURL: URL) throws -> URL` — unzip to cache keyed by SHA-256
    - Implement `hash(of fileURL: URL) throws -> String` — SHA-256 computation
    - Implement `purgeCacheIfNeeded()` — LRU purge until total < 50 MB
    - Cache directory: `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!/holoscape-skins/`
    - Validate all ZIP paths against cache root (reject `..` traversal, absolute paths, URL schemes)
    - Enforce 50 MB per-asset file-size cap during extraction
    - _Requirements: 7.2, 7.3, 7.4, 7.5, 17.1, 17.2, 17.3_

  - [ ]* 12.3 Write property test for ZIP path traversal rejection (Property 8)
    - **Property 8: ZIP Path Traversal Rejection**
    - **Validates: Requirements 7.4**
    - Create `Tests/HoloscapePropertyTests/WampPathTraversalPropertyTests.swift`
    - Generate random paths with/without traversal segments
    - Verify rejection for `..`, absolute paths, URL schemes; acceptance for clean relative paths

  - [ ]* 12.4 Write property test for LRU cache purge (Property 11)
    - **Property 11: LRU Cache Purge Correctness**
    - **Validates: Requirements 17.2**
    - Create `Tests/HoloscapePropertyTests/CachePurgePropertyTests.swift`
    - Generate random cache entry sets with sizes and timestamps
    - Verify LRU entries removed first, MRU preserved, total under 50 MB after purge

  - [ ] 12.5 Extend SkinEngine.availableSkins to enumerate .wamp files
    - Scan skins directory for `.wamp` files alongside directories
    - Display by manifest `name` field, falling back to filename without extension
    - "Default" always first in the list
    - _Requirements: 7.1, 7.8_

  - [ ]* 12.6 Write property test for skin enumeration (Property 7)
    - **Property 7: Skin Enumeration Includes Both Directory and .wamp Skins**
    - **Validates: Requirements 7.1**
    - Create `Tests/HoloscapePropertyTests/SkinEnumerationPropertyTests.swift`
    - Generate random directory layouts with .wamp files and directories
    - Verify all valid skins listed, "Default" always first (25 iterations, disk I/O)

  - [ ] 12.7 Extend SkinEngine.loadComposite for .wamp bundles
    - Detect `.wamp` URLs, delegate to WampLoader for extraction
    - Resolve manifest from cached directory
    - Parse skin.json, load images, load ninepatches, register fonts — same pipeline as directory skins
    - Convert WampLoader errors to `SkinLoadError.parseFailure`
    - _Requirements: 7.2, 7.6_

  - [ ] 12.8 Extend FSEventStream watcher for .wamp hot reload
    - Watch the `.wamp` file itself (not the cache directory)
    - On change: re-compute SHA-256, re-extract if hash changed, reload via loadComposite
    - Debounce with 200 ms trailing-edge window
    - Handle mid-unzip modification: keep previous SkinContext, log warning, retry next event
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

- [ ] 13. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 14. Manifest round-trip and robustness property tests
  - [ ]* 14.1 Write property test for SkinDefinition v3 round-trip (Property 1)
    - **Property 1: SkinDefinition v3 Manifest Round-Trip**
    - **Validates: Requirements 9.5, 12.5, 13.5**
    - Create `Tests/HoloscapePropertyTests/AmplifyManifestRoundTripPropertyTests.swift`
    - Generate random SkinDefinition with all v1/v2/v3 fields (windowShape, dragRegions, sprite fills)
    - Verify encode → decode produces equivalent object (100 iterations)

  - [ ]* 14.2 Write property test for malformed manifest robustness (Property 10)
    - **Property 10: Malformed Manifest Robustness**
    - **Validates: Requirements 15.6**
    - Create `Tests/HoloscapePropertyTests/MalformedManifestPropertyTests.swift`
    - Generate random byte sequences as skin.json content
    - Verify SkinEngine.loadSkin returns valid SkinDefinition or nil — never crashes (100 iterations)

- [ ] 15. Create reference skins
  - [ ] 15.1 Port HoloscapeSynthwave to .wamp bundle format
    - Package existing HoloscapeSynthwave skin's `skin.json`, `assets/`, and `fonts/` into a ZIP with `.wamp` extension
    - Verify pixel-identical rendering between directory-layout and .wamp versions
    - Both formats coexist in bundled resources
    - _Requirements: 10.1, 10.2, 10.3_

  - [ ] 15.2 Create Holoscape Classic reference skin
    - Create a skin with non-rectangular `windowShape` using polygon regions
    - Include at least one sprite-sheet image fill with normal/hover/pressed states for tab buttons
    - Ship a TTF font referenced in surface descriptors for TabBarView and SidebarView
    - Declare at least one drag region polygon
    - Include border/corner/shadow descriptors to exercise depth rendering
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5_

- [ ] 16. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation after each major phase
- Property tests validate universal correctness properties from the design document
- All new manifest fields are optional with nil defaults — backward compatibility is preserved throughout
- The feature flag `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` gates only shaped-window rendering; all other Amplify features are always active
- Implementation language is Swift (matching the existing codebase)
