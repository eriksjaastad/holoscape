# Requirements Document

## Introduction

Amplify extends Holoscape's chrome-skinning system from themeable chrome (color, gradient, ninepatch fills per surface) to Winamp-class skinning — shaped windows, per-element sprite art with interactive states, skin-authored click-through and drag regions, custom typography consumed by chrome views, border/corner/shadow depth on all chrome views, and a distributable `.wamp` bundle format. The goal is a macOS-native terminal whose skin can be as visually distinctive as any Winamp 2 skin from 1998.

The existing codebase provides `SkinEngine` (manifest loading, asset validation, font registration, FSEventStream hot reload), `SkinContext` (runtime appearance resolution, CALayer fill/border/corner/shadow application, state-variant evaluation), `SkinDefinition` (v1+v2 manifest model), `SurfaceDescriptor` (fill/border/corner/shadow/font/text/animation/state descriptors), `SurfaceKey` (23 compile-time surface identifiers), `ReactiveUniformSnapshot` (thread-safe state source for variant matching), `DensityModeManager` (Full/Minimal/Off density gating), and `ChromeRegionManager` (four external chrome bands). Amplify builds additively on all of these.

## Glossary

- **Skin_Engine**: The `SkinEngine` class responsible for discovering, loading, validating, and caching skins. Owns the FSEventStream file watcher and font registration lifecycle.
- **Skin_Context**: The `SkinContext` class that chrome views query at runtime for resolved surface appearance (fill, border, corner, shadow, font, text). Immutable after construction; state-variant selection is driven by `ReactiveUniformSnapshot`.
- **Skin_Definition**: The `SkinDefinition` Codable model representing a skin manifest (`skin.json`). Supports v1 flat fields and v2 `surfaces` dictionary; Amplify adds v3 optional fields.
- **Surface_Descriptor**: The `SurfaceDescriptor` Codable model describing one chrome surface's visual properties (fill, border, corner, padding, shadow, font, text, animation, states).
- **Surface_Key**: The `SurfaceKey` enum providing compile-time-typed identifiers for every chrome surface the Skin_Context can resolve.
- **Fill_Descriptor**: The `FillDescriptor` enum representing a surface background — color, image (with tile mode), or gradient.
- **Sprite_Descriptor**: A new Codable struct describing sprite-sheet cell layout (cell dimensions, row/column count, state-to-cell mapping) attached to an image fill.
- **Window_Shape_Descriptor**: A new Codable struct declaring the window's non-rectangular shape via polygon vertex lists.
- **Drag_Region_Descriptor**: A new Codable struct declaring skin-authored drag-handle polygon regions.
- **Wamp_Bundle**: A ZIP-based distributable skin package with `.wamp` extension containing `skin.json`, optional `regions.json`, `assets/`, and optional `fonts/`.
- **Density_Mode_Manager**: The `DensityModeManager` class gating skin features at three levels: Full (all features), Minimal (color fills only, shapes preserved), Off (skin engine bypassed entirely).
- **Chrome_View**: Any AppKit view in the Holoscape chrome layer that resolves its appearance through Skin_Context — includes `TabBarView`, `SidebarView`, `InputBoxView`, `SessionLauncherView`, `SplitPaneView`, and `ReaderModeController`.
- **Reactive_Snapshot**: The `ReactiveUniformSnapshot` class providing thread-safe state values for state-variant matching in skin surfaces.
- **Polygon**: An ordered list of 2D points defining a closed region in content-view coordinates.
- **Hit_Test**: The `NSView.hitTest(_:)` override that determines whether a mouse event at a given point should be received by the window or passed through.

## Requirements

### Requirement 1: Shaped Window Rendering via Polygon Regions

**User Story:** As a skin author, I want to declare non-rectangular window shapes using polygon vertex lists, so that Holoscape can render visually distinctive window silhouettes.

#### Acceptance Criteria

1. WHEN a skin manifest contains a `windowShape` field with `kind` equal to `"polygons"` and a valid `polygons` array, THE Skin_Engine SHALL parse the Window_Shape_Descriptor and pass the polygon data to the Skin_Context.
2. WHEN a shaped-window skin is applied, THE MainWindowController SHALL switch the NSWindow to `styleMask: .borderless`, set `isOpaque` to false, set `backgroundColor` to `.clear`, and apply a `CAShapeLayer` mask to `contentView.layer` built from the polygon vertices.
3. WHEN a skin manifest contains no `windowShape` field, THE MainWindowController SHALL retain the default titled resizable NSWindow style (backward compatible).
4. WHEN a skin's `windowShape.polygons` array contains polygons whose vertices all fall outside the content view's nominal bounds, THE Skin_Engine SHALL reject the manifest with a logged error and fall back to a rectangular window shape.
5. WHEN the user switches from a shaped-window skin to a rectangular skin (or vice versa), THE MainWindowController SHALL preserve the window frame origin and content across the style-mask transition.
6. WHILE macOS Reduce Motion is enabled, THE MainWindowController SHALL skip the fade animation during shaped-window transitions and apply the new shape immediately.
7. WHILE Density_Mode_Manager mode is `.off`, THE MainWindowController SHALL bypass shaped-window rendering and retain the default titled rectangular NSWindow.
8. WHILE Density_Mode_Manager mode is `.minimal`, THE MainWindowController SHALL apply the window shape mask (static shape preserved) but skip sprite-sheet and animation features.

### Requirement 2: Sprite-Sheet Image Fills with Interactive States

**User Story:** As a skin author, I want to define sprite sheets with per-state cells (normal, hover, pressed) for chrome elements, so that buttons and surfaces show bitmap art that responds to user interaction.

#### Acceptance Criteria

1. WHEN a Fill_Descriptor of kind `"image"` includes a `sprite` field with valid `cellWidth`, `cellHeight`, `rows`, `cols`, and `stateMap` entries, THE Skin_Engine SHALL parse the Sprite_Descriptor and attach it to the loaded image in the image cache.
2. WHEN a Chrome_View resolves a surface whose fill is a sprite-sheet image, THE Skin_Context SHALL slice the cell corresponding to the element's current interaction state (normal, hover, or pressed) and set the cropped sub-image as the CALayer's contents.
3. WHEN a sprite-sheet's `stateMap` does not contain an entry for the element's current state, THE Skin_Context SHALL fall back to the `"normal"` cell.
4. IF a sprite-sheet's `stateMap` contains no `"normal"` entry, THEN THE Skin_Engine SHALL log a warning and fall back to the first cell at row 0, column 0.
5. WHEN a Chrome_View receives a hover event (via NSTrackingArea), THE Chrome_View SHALL re-resolve its sprite fill to display the `"hover"` cell.
6. WHEN a Chrome_View receives a mouseDown event, THE Chrome_View SHALL re-resolve its sprite fill to display the `"pressed"` cell.
7. WHEN a Chrome_View receives a mouseUp or mouseExited event, THE Chrome_View SHALL re-resolve its sprite fill to display the `"normal"` cell.
8. WHILE Density_Mode_Manager mode is `.minimal`, THE Skin_Context SHALL substitute a solid color fallback for sprite-sheet image fills.
9. IF a sprite-sheet image file referenced in the manifest is missing or fails to decode, THEN THE Skin_Engine SHALL log a warning and THE Chrome_View SHALL fall back to its default color fill.

### Requirement 3: Click-Through Regions Outside Window Shape

**User Story:** As a user, I want mouse clicks on transparent areas outside the skin's declared window shape to pass through to windows behind Holoscape, so that shaped windows behave like native non-rectangular surfaces.

#### Acceptance Criteria

1. WHEN a shaped-window skin is active, THE MainWindowController SHALL override `contentView.hitTest(_:)` to return nil for points outside the current window-shape polygon region.
2. WHEN `hitTest(_:)` returns nil for a point, THE macOS window server SHALL pass the mouse event through to the window behind Holoscape.
3. THE Hit_Test implementation SHALL use a point-in-polygon algorithm for polygon-based shapes.
4. WHEN no `windowShape` is declared in the skin manifest, THE MainWindowController SHALL use the default rectangular hit-test behavior (entire content view is hittable).
5. THE Hit_Test evaluation SHALL complete within 1 millisecond for polygon regions containing up to 100 vertices, to avoid perceptible input lag.

### Requirement 4: Skin-Authored Drag Regions

**User Story:** As a skin author, I want to declare drag-handle regions in the skin manifest, so that users can move the window by grabbing skin-painted chrome areas instead of relying on a system title bar.

#### Acceptance Criteria

1. WHEN a skin manifest contains a `dragRegions` array with valid Drag_Region_Descriptor entries, THE Skin_Engine SHALL parse the polygon data and pass it to the Skin_Context.
2. WHEN a mouseDown event lands inside a declared drag region polygon, THE MainWindowController SHALL call `window.performDrag(with: event)` to initiate window movement.
3. WHEN the cursor hovers over a declared drag region, THE MainWindowController SHALL set the cursor to `NSCursor.openHand`.
4. WHEN a mouseDown occurs inside a declared drag region, THE MainWindowController SHALL set the cursor to `NSCursor.closedHand`.
5. WHEN a shaped-window skin declares no `dragRegions` AND the window is borderless, THE MainWindowController SHALL set `window.isMovableByWindowBackground` to true so the entire window is draggable as a fallback.
6. WHEN a drag region polygon has a bounding box smaller than 44×44 points, THE Skin_Engine SHALL log a warning at skin-load time referencing the Apple HIG minimum touch-target guideline.
7. WHEN no `windowShape` is declared (rectangular window with system title bar), THE MainWindowController SHALL ignore `dragRegions` and rely on the system-provided title-bar drag behavior.

### Requirement 5: Chrome Typography from Skin-Shipped Fonts

**User Story:** As a skin author, I want to ship TTF fonts in the skin bundle and have chrome views render labels in those fonts, so that the skin's visual identity extends to typography.

#### Acceptance Criteria

1. WHEN a skin manifest's surface descriptor includes a `font` field referencing a font family name that matches a registered skin font, THE Skin_Context SHALL resolve that font for the surface.
2. WHEN `TabBarView` resolves a surface with a non-nil font, THE TabBarView SHALL apply that font to its tab button labels in `refreshFromSkin()`.
3. WHEN `SidebarView` / `SidebarTabEntry` resolves a surface with a non-nil font, THE SidebarView SHALL apply that font to its label fields in `refreshFromSkin()`.
4. WHEN `InputBoxView` resolves a surface with a non-nil font, THE InputBoxView SHALL apply that font to its text view in `refreshFromSkin()`.
5. WHEN a skin manifest references a font family name that is not registered (missing TTF file or failed registration), THE Chrome_View SHALL fall back to the system monospaced font and THE Skin_Engine SHALL log a warning.
6. THE Skin_Engine SHALL register skin fonts at process scope via `CTFontManagerRegisterFontsForURL` (existing behavior) and unregister the previous skin's fonts before registering the new skin's fonts, maintaining the font registration symmetry invariant.
7. THE Skin_Engine SHALL NOT register skin fonts at persistent scope — skin fonts SHALL NOT appear in Font Book or persist after Holoscape quits.

### Requirement 6: Border, Corner, and Shadow Rendering on All Chrome Views

**User Story:** As a skin author, I want border, corner radius, and shadow descriptors from the manifest to be applied by every chrome view, so that skins can add bevels, glows, and depth to the chrome.

#### Acceptance Criteria

1. WHEN a surface descriptor includes a `border` field, THE Chrome_View SHALL call `skinContext.applyBorderAndCorner(to:from:)` in its `refreshFromSkin()` method to apply the border color and width to its backing CALayer.
2. WHEN a surface descriptor includes a `corner` field, THE Chrome_View SHALL apply the corner radius (uniform or asymmetric) to its backing CALayer via `skinContext.applyBorderAndCorner(to:from:)`.
3. WHEN a surface descriptor includes a `shadow` field, THE Skin_Context SHALL apply the shadow color, opacity, blur radius, and offset to the CALayer's shadow properties.
4. THE following Chrome_Views SHALL call `applyBorderAndCorner` and shadow application in their `refreshFromSkin()`: TabBarView, SidebarView, SidebarTabEntry, InputBoxView, SessionLauncherView, SplitPaneView, and the settings/dialog containers.
5. WHEN a surface descriptor omits border, corner, or shadow fields, THE Chrome_View SHALL render with no border (width 0), no corner radius (0), and no shadow (opacity 0) — matching pre-skinning defaults.

### Requirement 7: `.wamp` Bundle Format — Loader and Cache

**User Story:** As a skin author, I want to package skins as single `.wamp` ZIP files for easy distribution, so that users can install skins by dropping a file into their skins directory.

#### Acceptance Criteria

1. THE Skin_Engine SHALL recognize files with the `.wamp` extension in the skins directory (`~/.holoscape/skins/`) alongside directory-layout skins when enumerating available skins.
2. WHEN `Skin_Engine.loadComposite(named:)` resolves a skin URL to a `.wamp` file, THE Skin_Engine SHALL unzip the bundle to a cache directory at `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!/holoscape-skins/<hash>/` and resolve the manifest from the cached directory.
3. THE Skin_Engine SHALL key the cache by SHA-256 hash of the `.wamp` file so that edits to the bundle invalidate the cache.
4. THE Skin_Engine SHALL validate all paths inside the ZIP archive against the cache root — rejecting entries containing `..` traversal segments or absolute paths — before extracting any files.
5. THE Skin_Engine SHALL enforce a 50 MB per-asset file-size cap during unzip and abort extraction when the cap is breached, logging the violation and notifying the user.
6. WHEN a `.wamp` bundle is loaded successfully, THE Skin_Engine SHALL parse `skin.json` from the extracted cache, load images from `assets/`, load ninepatch sidecars, and register fonts from `fonts/` — using the same pipeline as directory-layout skins.
7. THE Skin_Engine SHALL include a `ZIPFoundation` (or equivalent pure-Swift ZIP library) dependency for `.wamp` extraction.
8. WHEN `Skin_Engine.availableSkins()` lists skins, THE Skin_Engine SHALL display `.wamp` skins by their manifest `name` field (falling back to the filename without extension when `name` is absent).

### Requirement 8: `.wamp` Bundle Hot Reload

**User Story:** As a skin author iterating on a `.wamp` bundle, I want Holoscape to detect changes to the bundle file and reload the skin within 200 milliseconds, so that I get rapid visual feedback without restarting.

#### Acceptance Criteria

1. WHEN a `.wamp` bundle is the active skin, THE Skin_Engine SHALL watch the `.wamp` file itself (not the cache directory) via FSEventStream for modification events.
2. WHEN the FSEventStream fires for the active `.wamp` file, THE Skin_Engine SHALL re-compute the SHA-256 hash, re-extract to a new cache entry if the hash changed, and reload the skin through the standard `loadComposite` pipeline.
3. THE MainWindowController SHALL debounce FSEventStream events with a 200 ms trailing-edge window (matching the existing directory-layout debounce behavior) before triggering a reload.
4. IF the `.wamp` file is modified mid-unzip (race with editor save), THEN THE Skin_Engine SHALL keep the previous Skin_Context active and log a warning, retrying on the next FSEventStream event.
5. WHEN a `.wamp` hot reload completes successfully, THE MainWindowController SHALL apply the new Skin_Context to all Chrome_Views and post a `.skinDidChange` notification.

### Requirement 9: Backward Compatibility with Existing v2 Skin Manifests

**User Story:** As an existing Holoscape user with a v2 directory-layout skin, I want my skin to continue working without modification after Amplify ships, so that the upgrade is non-breaking.

#### Acceptance Criteria

1. THE Skin_Engine SHALL continue to load v1 and v2 `skin.json` manifests from directory-layout skins at `~/.holoscape/skins/<name>/skin.json` without requiring any manifest changes.
2. WHEN a v2 manifest contains no `windowShape`, `dragRegions`, or `sprite` fields, THE Skin_Engine SHALL treat the skin as a rectangular-window, color/gradient/image-fill skin — identical to pre-Amplify behavior.
3. THE Skin_Definition model SHALL add all Amplify-specific fields (`windowShape`, `dragRegions`, sprite support in Fill_Descriptor) as optional properties with nil defaults, preserving Codable backward compatibility.
4. WHEN the existing `HoloscapeSynthwave` reference skin is loaded after Amplify ships, THE Skin_Engine SHALL produce a Skin_Context identical to the pre-Amplify version — no visual regression.
5. FOR ALL valid v2 Skin_Definition manifests, encoding then decoding the manifest SHALL produce an equivalent Skin_Definition object (round-trip property).

### Requirement 10: Reference Skin — HoloscapeSynthwave Ported to `.wamp`

**User Story:** As a developer validating the `.wamp` pipeline, I want the existing HoloscapeSynthwave skin repackaged as a `.wamp` bundle, so that the bundle format is proven with a known-good skin.

#### Acceptance Criteria

1. THE project SHALL include a `HoloscapeSynthwave.wamp` file containing the existing HoloscapeSynthwave skin's `skin.json`, `assets/`, and `fonts/` (if any) in the `.wamp` ZIP layout.
2. WHEN `HoloscapeSynthwave.wamp` is loaded, THE Skin_Engine SHALL produce chrome rendering pixel-identical to the directory-layout `HoloscapeSynthwave` skin on the same monitor and backing scale.
3. THE directory-layout `HoloscapeSynthwave` skin SHALL remain in the bundled resources alongside the `.wamp` version — both formats coexist.

### Requirement 11: Reference Skin — Holoscape Classic (Winamp-Evocative)

**User Story:** As a user, I want a bundled "Holoscape Classic" skin that exercises shaped windows, sprite-sheet buttons, and skin fonts, so that Amplify's capabilities are demonstrated out of the box.

#### Acceptance Criteria

1. THE project SHALL include a "Holoscape Classic" skin (directory-layout or `.wamp`) that declares a non-rectangular `windowShape` using polygon regions.
2. THE "Holoscape Classic" skin SHALL include at least one sprite-sheet image fill with `normal`, `hover`, and `pressed` state cells for tab-bar buttons.
3. THE "Holoscape Classic" skin SHALL ship a TTF font and reference it in surface descriptors for `TabBarView` and `SidebarView` labels.
4. THE "Holoscape Classic" skin SHALL declare at least one drag region polygon.
5. WHEN the "Holoscape Classic" skin is selected, THE MainWindowController SHALL render a non-rectangular window with sprite-art tab buttons, skin-font labels, and a functional drag region.

### Requirement 12: Manifest Parsing — Window Shape and Drag Regions

**User Story:** As a developer, I want the skin manifest parser to handle the new `windowShape` and `dragRegions` fields, so that the data model supports Amplify skins.

#### Acceptance Criteria

1. THE Skin_Definition model SHALL include an optional `windowShape` property of type `WindowShapeDescriptor` that decodes from the `"windowShape"` JSON key.
2. THE Window_Shape_Descriptor SHALL include a `kind` field (enum: `"polygons"`) and a `polygons` array of Polygon objects, each containing a `points` array of `{x, y}` coordinate pairs.
3. THE Skin_Definition model SHALL include an optional `dragRegions` property of type `[DragRegionDescriptor]` that decodes from the `"dragRegions"` JSON key.
4. THE Drag_Region_Descriptor SHALL include a `polygons` array of Polygon objects.
5. FOR ALL valid Skin_Definition manifests containing `windowShape` and `dragRegions`, encoding then decoding SHALL produce an equivalent Skin_Definition object (round-trip property).
6. WHEN a manifest contains an unknown `windowShape.kind` value, THE Skin_Engine SHALL log a warning and ignore the `windowShape` field (forward compatibility).

### Requirement 13: Manifest Parsing — Sprite Descriptor Extension to Fill_Descriptor

**User Story:** As a developer, I want the Fill_Descriptor image variant to support an optional sprite metadata field, so that sprite-sheet fills can be declared in skin manifests.

#### Acceptance Criteria

1. THE Fill_Descriptor `.image` case SHALL accept an optional `sprite` parameter of type `SpriteDescriptor`.
2. THE Sprite_Descriptor SHALL include `cellWidth: Int`, `cellHeight: Int`, `rows: Int`, `cols: Int`, and `stateMap: [String: SpriteCell]` fields.
3. THE SpriteCell struct SHALL include `row: Int` and `col: Int` fields identifying the cell position in the sprite sheet.
4. WHEN a Fill_Descriptor of kind `"image"` omits the `sprite` field, THE Skin_Engine SHALL treat the image as a whole-image fill (backward compatible with existing image fills).
5. FOR ALL valid Fill_Descriptor values with sprite metadata, encoding then decoding SHALL produce an equivalent Fill_Descriptor (round-trip property).

### Requirement 14: Surface Key Catalog Expansion

**User Story:** As a developer, I want new Surface_Key cases for interactive element states and the reader panel, so that sprite-sheet fills and reader-panel skinning have compile-time-typed surface identifiers.

#### Acceptance Criteria

1. THE Surface_Key enum SHALL include new cases for tab-bar interactive states: `tabBarTabHover` (`"tabBar.tab.hover"`) and `tabBarTabPressed` (`"tabBar.tab.pressed"`).
2. THE Surface_Key enum SHALL include new cases for sidebar interactive states: `sidebarRowPressed` (`"sidebar.row.pressed"`).
3. THE Surface_Key enum SHALL include new cases for session launcher button states: `sessionLauncherButtonNormal` (`"sessionLauncher.button.normal"`), `sessionLauncherButtonHover` (`"sessionLauncher.button.hover"`), `sessionLauncherButtonPressed` (`"sessionLauncher.button.pressed"`).
4. THE Surface_Key enum SHALL include new cases for the reader panel: `readerPanelTitleBar` (`"readerPanel.titleBar"`), `readerPanelBackground` (`"readerPanel.background"`), `readerPanelCloseButtonNormal` (`"readerPanel.closeButton.normal"`), `readerPanelCloseButtonHover` (`"readerPanel.closeButton.hover"`), `readerPanelCloseButtonPressed` (`"readerPanel.closeButton.pressed"`).
5. THE Skin_Context `defaultSurface(for:)` method SHALL return sensible built-in defaults for all new Surface_Key cases.

### Requirement 15: Graceful Degradation for Malformed Skins

**User Story:** As a user, I want a broken or incomplete skin to degrade gracefully without crashing or bricking the app, so that I can always recover to a working state.

#### Acceptance Criteria

1. IF a `skin.json` file fails to parse, THEN THE Skin_Engine SHALL exclude the skin from the available skins list and log the specific parse error.
2. IF a `regions.json` file (for polygon shapes) fails to parse, THEN THE Skin_Engine SHALL load the skin with a rectangular window shape fallback and log a warning.
3. IF a sprite-sheet image referenced in the manifest is missing, THEN THE Chrome_View SHALL render with its default color fill and THE Skin_Engine SHALL log a warning.
4. IF a font file referenced in the manifest fails to register, THEN THE Chrome_View SHALL render with the system monospaced font and THE Skin_Engine SHALL log a warning.
5. IF a `.wamp` bundle fails to unzip (corrupt archive, path traversal violation, size cap breach), THEN THE Skin_Engine SHALL exclude the skin from the available skins list and log the specific error.
6. THE Skin_Engine SHALL NOT throw unhandled exceptions during skin loading — all errors SHALL be caught, logged, and result in graceful fallback.

### Requirement 16: Accessibility Compliance for Shaped Windows

**User Story:** As a user with accessibility needs, I want shaped windows to respect macOS accessibility settings, so that Holoscape remains usable with assistive technologies.

#### Acceptance Criteria

1. WHILE macOS Reduce Transparency is enabled, THE MainWindowController SHALL render shaped-window masked regions as opaque system-gray instead of transparent.
2. THE Chrome_Views SHALL retain their existing accessibility labels, roles, and identifiers regardless of the active skin — skin visuals SHALL NOT override code-provided accessibility metadata.
3. WHEN VoiceOver is active, THE Chrome_Views SHALL remain navigable and announce their accessibility titles and values as they do with the default rectangular window.

### Requirement 17: `.wamp` Bundle Cache Management

**User Story:** As a user, I want the `.wamp` cache to be managed automatically so it does not consume unbounded disk space.

#### Acceptance Criteria

1. THE Skin_Engine SHALL enforce a 50 MB total cap on the `.wamp` unzip cache directory.
2. WHEN the cache exceeds the 50 MB cap, THE Skin_Engine SHALL purge the least-recently-used cache entries until the total is under the cap.
3. THE Skin_Engine SHALL run the cache purge check on application startup.

### Requirement 18: Feature Flag for Shaped Windows

**User Story:** As a developer, I want shaped-window rendering gated behind a feature flag, so that shape-related rendering bugs can be isolated without reverting the entire Amplify feature set.

#### Acceptance Criteria

1. THE MainWindowController SHALL check for the `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` environment variable before applying shaped-window rendering.
2. WHEN `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` is absent or set to `"0"`, THE MainWindowController SHALL ignore `windowShape` declarations and render all skins as rectangular windows.
3. WHEN `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` is set to `"1"`, THE MainWindowController SHALL apply shaped-window rendering as specified in Requirement 1.
4. THE feature flag SHALL NOT affect non-shape Amplify features (sprite sheets, fonts, borders, `.wamp` loading) — those SHALL be active regardless of the flag.
