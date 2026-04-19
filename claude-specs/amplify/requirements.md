# Requirements Document: Amplify — Winamp-class Chrome Skinning

> **Reconciled 2026-04-19** against the Kiro-generated parallel spec at `.kiro/specs/amplify-skinning/`. Three Kiro-sourced changes were merged:
> 1. Mask-image shapes (`kind: mask`) deferred to post-MVP per PRD §12 (previously MVP in Claude's draft); MVP ships polygons only.
> 2. Sprite rendering documented as `layer.contentsRect` UV offset on the shared sheet rather than per-state bitmap slicing (GPU-friendly, no per-state NSImage allocation).
> 3. Font registration invariants stated explicitly as SHALL statements — process scope only, never Font Book, never persistent — lifted from Kiro Req 5.6-5.7.

## Introduction

Amplify is the 2026 extension of Holoscape's chrome-skinning engine from "themeable rectangles" to "Winamp-class skinning." The parent chrome-skinning system (claude-specs/chrome-skinning/, Task Groups 1-13 merged via PRs #98-#115) established a v2 manifest format, a `SkinContext` / `SkinEngine` / `SurfaceKey` catalog, the `SurfaceDescriptor` model tree (fill, border, corner, padding, shadow, font, text, animation, state variants), an image asset pipeline, font registration, hot reload via FSEventStream, and a reference skin (`HoloscapeSynthwave`). It shipped a themeable but still-rectangular chrome where borders, corners, shadows, and fonts were parsed but never consumed by chrome views.

Amplify closes the six gaps Erik identified during 2026-04-18 Mac Mini dogfood: (1) every window is a rectangle, (2) buttons are colored boxes, (3) there is no skin-authored hit testing, (4) tab titles and sidebar labels render in the system font regardless of skin, (5) `BorderDescriptor` / `CornerDescriptor` / `ShadowDescriptor` from the manifest are parsed but never applied by chrome views, (6) there is no distributable bundle format. Amplify adds shaped windows (`NSWindow(styleMask: .borderless)` + `contentView.layer.mask`), per-element sprite sheets with state rows (normal / hover / pressed / active / disabled), click-through and drag regions via `hitTest(_:)` override plus polygon sampling, chrome-view consumption of TTF fonts and border/corner/shadow descriptors, and a `.wamp` ZIP bundle format.

The target platform is macOS 15+ (Apple Silicon) via AppKit / Swift 6. No cross-platform work, no SwiftUI port, no Catalyst. Amplify is additive to v2 — existing v2 manifests under `~/.holoscape/skins/<name>/` continue to load and render without modification. All new manifest fields are optional and have documented defaults that reproduce pre-Amplify behavior. A skin that omits every Amplify field renders identically to its v2 form.

## Glossary

- **Amplify_Manifest**: A `Skin_Definition` manifest with `version: "3.0"` and one or more Amplify-only fields (`windowShape`, `dragRegions`, sprite descriptors, or new `Surface_Key` cases)
- **Cache_Root**: The directory at `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!` / `Holoscape/Skins/` where `.wamp` bundles are unzipped, keyed by SHA-256 of the bundle bytes
- **Drag_Region_Descriptor**: A `Polygon` set in the manifest declaring where in the content view a `mouseDown` initiates a window drag via `NSWindow.performDrag(with:)`
- **Font_Registry**: The per-skin map from PostScript name to `CGFont` populated by `SkinEngine.registerFonts(from:)`; chrome views read from the active `Skin_Context.fontRegistry` when resolving `Font_Descriptor.family`
- **Hit_Region_Sampler**: The point-in-polygon test (Jordan curve theorem / ray casting) used by `hitTest(_:)` to decide whether a content-view point is inside `Window_Shape_Descriptor.polygons`
- **Polygon**: An ordered list of at least three `Point` vertices (x, y in content-view coordinates) that defines one closed region
- **Shape_Renderer**: The subsystem (`ShapedWindowController` + `contentView.layer.mask`) that converts a `Window_Shape_Descriptor` into a `CAShapeLayer` applied to the window's content view
- **Skin_Context**: The existing `@MainActor final class SkinContext` (`Services/SkinContext.swift`) — extended in Amplify to carry `windowShape`, `dragRegions`, `fontRegistry`, and sprite-aware `applyFill` overloads
- **Skin_Engine**: The existing `SkinEngine` (`Services/SkinEngine.swift`) — extended in Amplify to recognize `.wamp` files in addition to directory-layout skins
- **Sprite_Descriptor**: Optional metadata on `Fill_Descriptor.image` declaring cell dimensions (`cellWidth`, `cellHeight`), grid shape (`rows`, `cols`), and a `stateMap` mapping state names to cells
- **Sprite_State**: One of `normal`, `hover`, `pressed`, `active`, `disabled`, `focused`, `selected`; chrome views publish their current state and the sprite renderer slices the corresponding cell
- **Surface_Key**: The existing `enum SurfaceKey` (`Models/SurfaceKey.swift`) — Amplify grows the catalog from 23 cases to cover per-state interactive surfaces (`tabBar.tab.hover`, `tabBar.tab.pressed`, `sidebar.row.pressed`, `sessionLauncher.button.*`, `readerPanel.*`, `window.shape`, `window.dragHandle`)
- **Wamp_Bundle**: A ZIP archive with extension `.wamp` containing `skin.json`, optional `regions.json`, an `assets/` directory of PNGs and optional `.ninepatch.json` sidecars, and an optional `fonts/` directory of TTF/OTF files
- **Wamp_Cache**: See **Cache_Root**
- **Window_Shape_Descriptor**: A new manifest field declaring the window's non-rectangular shape as a list of polygons (`kind: polygons`). A `kind: mask` PNG-alpha variant is deferred to post-MVP per PRD §12 — MVP ships polygons only.
- **Zip_Sandbox**: The two-layer validation (string-gate + symlink-resolve-gate) applied to every file extracted from a `Wamp_Bundle`, identical to the asset-path sandbox used for directory-layout skins

## Requirements

### Requirement 1: `.wamp` Bundle Loading

**User Story:** As Erik, I want to drop a `.wamp` file into my skins folder and have Holoscape treat it exactly like a directory-layout skin, so that I can install a skin by copying one file instead of a directory tree.

#### Acceptance Criteria

1. THE Holoscape SHALL enumerate files with extension `.wamp` under `~/.holoscape/skins/` (or the `HOLOSCAPE_CONFIG_DIR` override) and under the app bundle's `Resources/Skins/` alongside directory-layout skins and list them in the Appearance Settings picker by their filename without the `.wamp` extension.
2. WHEN the user selects a `.wamp` skin, THE Holoscape SHALL compute the SHA-256 of the bundle's bytes, resolve the `Cache_Root` subdirectory keyed by the hash, and unzip the bundle to that subdirectory if it does not already exist.
3. WHEN unzipping a `Wamp_Bundle`, THE Holoscape SHALL validate every entry path through the `Zip_Sandbox` and reject the bundle if any entry uses `..` traversal, an absolute path, or a symlink whose resolved target lies outside the cache subdirectory.
4. IF a `Wamp_Bundle` contains any single asset larger than 50 MB uncompressed, THEN THE Holoscape SHALL abort the unzip, log the offending path, and fall back to the previous `Skin_Context`.
5. IF a `Wamp_Bundle` fails to open as a ZIP archive, contains no `skin.json`, or fails `skin.json` decoding, THEN THE Holoscape SHALL log the error, leave the previous `Skin_Context` intact, and continue running.
6. THE Holoscape SHALL resolve the `Skin_Engine` pipeline (manifest parse, image load, ninepatch load, font registration, surfaces conversion) from the unzipped cache subdirectory, reusing the existing `loadComposite(named:)` pipeline.
7. WHEN a user-installed skin at `~/.holoscape/skins/<name>.wamp` shares a name with a bundled directory-layout skin or bundled `.wamp`, THE Holoscape SHALL prefer the user-installed bundle.
8. WHEN the total size of `Cache_Root` exceeds 50 MB, THE Holoscape SHALL purge least-recently-used cache subdirectories at launch until the total size is at or below 50 MB, preserving the currently-active skin's cache subdirectory.

### Requirement 2: Shaped Window Rendering

**User Story:** As Erik, I want skins to declare non-rectangular window shapes so that Holoscape can have the visual identity of a 1998 Winamp skin, not a rectangle with gradients.

#### Acceptance Criteria

1. WHEN the active skin's manifest contains a `Window_Shape_Descriptor` with `kind: polygons`, THE Holoscape SHALL reconstruct the main window with `styleMask: .borderless`, set `isOpaque = false`, set `backgroundColor = .clear`, and install a `CAShapeLayer` as `contentView.layer.mask` whose path is the union of the declared polygons in content-view coordinates.
2. WHEN the active skin's manifest contains no `Window_Shape_Descriptor`, THE Holoscape SHALL use the pre-Amplify titled/resizable `NSWindow` configuration with its default style mask.
3. WHEN switching between a rectangular skin and a shaped skin, THE Holoscape SHALL preserve the window's `frame` (origin and size) across the style-mask swap and restore key-window and first-responder status on the new window.
4. IF a `Window_Shape_Descriptor` polygon set contains any polygon whose bounding box lies entirely outside the nominal window content-view bounds, THEN THE Holoscape SHALL reject the descriptor at load time, log the offending polygon index, and fall back to the rectangular window configuration.
5. WHILE a shaped window is active, THE Holoscape SHALL let AppKit's native window shadow follow the mask (no manual shadow construction).
6. WHEN the user's macOS system preference Reduce Transparency is enabled, THE Holoscape SHALL replace alpha-masked regions with opaque system-gray and preserve the shape outline.
7. WHEN the user's macOS system preference Reduce Motion is enabled, THE Holoscape SHALL omit the fade transition on shape swap and apply the new shape immediately.
8. WHILE the `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` environment variable is absent or set to `0`, THE Holoscape SHALL bypass all shaped-window code paths and keep the pre-Amplify titled/resizable window regardless of manifest content.
9. IF a `Window_Shape_Descriptor` declares `kind: mask`, THEN THE Holoscape SHALL reject the descriptor at load time, log `"kind: mask is post-MVP; ignoring shape"`, and fall back to the rectangular window configuration. Mask-image (PNG alpha) shapes are deferred to post-MVP per PRD §12.

### Requirement 3: Click-Through Hit Testing

**User Story:** As Erik, I want pixels outside the declared window shape to pass mouse events through to whatever is behind Holoscape, so that shaped windows behave like Winamp skins did: the visible shape is the window, the invisible pixels are not.

#### Acceptance Criteria

1. WHILE a `Window_Shape_Descriptor` with `kind: polygons` is active, THE Holoscape SHALL override `NSView.hitTest(_:)` on the content view to return `nil` for points the `Hit_Region_Sampler` reports as outside every declared polygon.
2. THE Holoscape SHALL implement the `Hit_Region_Sampler` using ray-casting (Jordan curve theorem) so that every point on a polygon edge or vertex is deterministically classified as inside.
3. WHEN a `hitTest(_:)` resolves to a point inside a sub-view that has opted in to hit testing (tab button, sidebar row, input field), THE Holoscape SHALL return that sub-view rather than the content view.
4. THE Holoscape SHALL evaluate the `Hit_Region_Sampler` in under 100 microseconds for a polygon set of up to 64 vertices on Apple Silicon.

### Requirement 4: Skin-Authored Drag Regions

**User Story:** As Erik, I want skins to declare which painted chrome regions are draggable, so that users can move a borderless shaped window by grabbing its skin-painted title area instead of a system title bar.

#### Acceptance Criteria

1. WHEN a `Drag_Region_Descriptor` is present in the manifest, THE Holoscape SHALL install an `NSTrackingArea` over each declared polygon on the content view.
2. WHEN a `mouseDown(with:)` event lands on a point inside any `Drag_Region_Descriptor` polygon, THE Holoscape SHALL invoke `window.performDrag(with:)` and swallow the event.
3. WHILE the cursor hovers a `Drag_Region_Descriptor` polygon AND no mouse button is pressed, THE Holoscape SHALL push `NSCursor.openHand` onto the cursor stack.
4. WHILE the cursor hovers a `Drag_Region_Descriptor` polygon AND the left mouse button is pressed, THE Holoscape SHALL push `NSCursor.closedHand` onto the cursor stack.
5. IF a `Drag_Region_Descriptor` polygon's bounding box has width or height under 44 points, THEN THE Holoscape SHALL log a HIG violation warning at skin-load time naming the offending polygon index.
6. IF the active skin uses a borderless window AND declares no `Drag_Region_Descriptor`, THEN THE Holoscape SHALL set `NSWindow.isMovableByWindowBackground = true` so the entire content view remains draggable.
7. WHEN a `Drag_Region_Descriptor` specifies `modifier: "command"`, THE Holoscape SHALL initiate the drag only when `NSEvent.modifierFlags.contains(.command)` at `mouseDown` time.

### Requirement 5: Sprite-Sheet Fills

**User Story:** As Erik, I want skins to ship sprite sheets with state rows so that a tab button can show distinct artwork for normal / hover / pressed / active instead of recolored rectangles.

#### Acceptance Criteria

1. WHEN a `Fill_Descriptor` with `kind: image` carries a `Sprite_Descriptor`, THE Holoscape SHALL slice the cell at row `stateMap[currentState].row`, column `stateMap[currentState].col` of size (`cellWidth`, `cellHeight`) and set that cropped `NSImage` as the layer's `contents`.
2. WHEN a chrome view transitions between `Sprite_State` values, THE Holoscape SHALL recompute the sliced cell and reapply `contents` within 16 milliseconds of the state change.
3. IF a `Sprite_Descriptor.stateMap` does not include a mapping for the current `Sprite_State`, THEN THE Holoscape SHALL fall back to the `normal` cell and, if `normal` is also absent, the full image with stretch tile mode.
4. IF a `Sprite_Descriptor.cellWidth * cols` exceeds the sprite-sheet image width OR `cellHeight * rows` exceeds the image height, THEN THE Holoscape SHALL reject the descriptor at load time, log the dimension mismatch, and fall back to stretch-mode fill.
5. THE Holoscape SHALL publish `Sprite_State` transitions from chrome views through `NSTrackingArea` (for `hover`), `NSButton.isHighlighted` / control-event tracking (for `pressed`), the active-tab selection model (for `active`), the focus state (for `focused`), and the first-responder / selection state (for `selected`).
6. WHILE the density mode is `.minimal`, THE Holoscape SHALL bypass sprite slicing and render the full sprite-sheet image in stretch tile mode.
7. THE Holoscape SHALL render sliced sprite cells with `CALayer.contentsScale` set to the hosting window's `backingScaleFactor` so that sprites render crisply on Retina displays.

### Requirement 6: Chrome Font Consumption

**User Story:** As Erik, I want tab titles, sidebar labels, input prompts, and launcher rows to render in the skin's bundled typeface so that a pixel-font skin looks like a pixel-font skin.

#### Acceptance Criteria

1. WHEN a `Surface_Descriptor` has a `Font_Descriptor.family`, THE Holoscape SHALL look up the family in `Skin_Context.fontRegistry` first and, on miss, fall back to system font resolution via `NSFont(name:size:)`.
2. WHEN a chrome view runs `refreshFromSkin()`, THE Holoscape SHALL apply the resolved `NSFont` to the view's labels, text fields, and button titles for the view's `Surface_Key`.
3. IF a `Surface_Descriptor` omits `font`, THEN THE Holoscape SHALL retain the pre-Amplify system font for that view.
4. IF a `Font_Descriptor.family` resolves to neither a registered skin font nor a system font, THEN THE Holoscape SHALL fall back to `NSFont.monospacedSystemFont(ofSize:weight:)` and log a warning naming the unresolved family.
5. THE Holoscape SHALL apply skin fonts to `TabBarView`, `SidebarView` / `SidebarTabEntry`, `InputBoxView`, and `SessionLauncherView` in MVP.
6. THE Holoscape SHALL accept `weight` values `regular`, `medium`, `bold`, `semibold`, `light`, `thin`, `heavy`, `black`, and `ultraLight`; unknown weights fall back to `regular`.
7. THE `Skin_Engine` SHALL register skin fonts via `CTFontManagerRegisterFontsForURL(_, .process, _)` (existing chrome-skinning behavior) and unregister the previous skin's fonts before registering the new skin's fonts, maintaining the font-registration symmetry invariant from the parent spec.
8. THE `Skin_Engine` SHALL NOT register skin fonts at persistent scope — skin fonts SHALL NOT appear in Font Book and SHALL NOT persist after Holoscape quits.

### Requirement 7: Chrome Border, Corner, and Shadow Consumption

**User Story:** As Erik, I want skins to add bevels, glows, and beveled corners to chrome views so that a skin can look three-dimensional instead of flat rectangles with gradients.

#### Acceptance Criteria

1. WHEN a chrome view runs `refreshFromSkin()`, THE Holoscape SHALL call `SkinContext.applyBorderAndCorner(to: layer, from: resolved)` with the view's layer and resolved surface.
2. WHEN a chrome view runs `refreshFromSkin()` AND the resolved surface has a non-nil `shadow`, THE Holoscape SHALL set `layer.shadowColor`, `layer.shadowOpacity`, `layer.shadowRadius`, and `layer.shadowOffset` from the `Resolved_Shadow` values.
3. WHEN a chrome view runs `refreshFromSkin()` AND the resolved surface has a nil `shadow`, THE Holoscape SHALL set `layer.shadowOpacity = 0` and leave other shadow properties as-is.
4. THE Holoscape SHALL apply border, corner, and shadow to `TabBarView` tabs, `SidebarView` rows, `InputBoxView`, `SessionLauncherView`, and `ReaderModeController`'s chrome layer in MVP.
5. WHEN a `Corner_Descriptor` is `.uniform` with a value greater than half the tab button's height, THE Holoscape SHALL clamp the applied `cornerRadius` to half the height so corners render as a pill shape.
6. THE Holoscape SHALL leave chrome view geometry (frame, subview layout) unchanged when applying border, corner, and shadow.

### Requirement 8: Reader Panel Skinning

**User Story:** As Erik, I want Reader Mode to consume the active skin's chrome and typography so that opening the reader panel does not break the visual theme.

#### Acceptance Criteria

1. WHEN a `Surface_Descriptor` exists under the `Surface_Key` `readerPanel.background`, THE Holoscape SHALL apply its fill, border, corner, and shadow to the Reader Mode panel's background layer.
2. WHEN a `Surface_Descriptor` exists under `readerPanel.titleBar`, THE Holoscape SHALL apply its fill, border, and text properties to the Reader Mode panel's title-bar layer.
3. WHEN a `Surface_Descriptor` for `readerPanel.background` carries a `Font_Descriptor`, THE Holoscape SHALL apply the resolved font to the Reader Mode `NSTextView` in place of the hardcoded `NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)`.
4. IF no Reader Mode surface is defined in the manifest, THEN THE Holoscape SHALL retain the pre-Amplify Reader Mode look (SF Mono 14pt, default chrome).
5. WHEN a `Surface_Descriptor` exists under `readerPanel.closeButton.normal`, `readerPanel.closeButton.hover`, or `readerPanel.closeButton.pressed`, THE Holoscape SHALL resolve those surfaces for the Reader Mode close button's three states.
6. IF the user's macOS system preference Increase Contrast is enabled, THEN THE Holoscape SHALL ignore the skin's Reader Mode font and retain SF Mono 14pt regardless of manifest content.

### Requirement 9: Backward Compatibility

**User Story:** As Erik, I want every v2 manifest I have already written to continue working without modification, so that upgrading Holoscape never requires me to touch an existing skin.

#### Acceptance Criteria

1. WHEN Holoscape loads a manifest with `version` absent or `version: "2.0"`, THE Holoscape SHALL apply v2 semantics and treat every Amplify-only field (`windowShape`, `dragRegions`, sprite descriptors, new `Surface_Key` cases) as absent.
2. WHEN Holoscape loads a manifest with `version: "3.0"`, THE Holoscape SHALL accept every v2 field alongside every Amplify field.
3. WHEN Holoscape loads a v1 manifest (the 10 legacy color / image fields), THE Holoscape SHALL apply v1 semantics unchanged from pre-chrome-skinning behavior.
4. THE Holoscape SHALL render a v2 manifest on Amplify code paths with pixel-identical output to its pre-Amplify render, given identical monitor backing scale and identical `DensityMode`.
5. IF an `Amplify_Manifest` is loaded on a pre-Amplify Holoscape binary, THEN the build SHALL decode the manifest with Amplify fields silently ignored (forward compat via `decodeIfPresent`).
6. THE Holoscape SHALL document every Amplify field as optional with a documented default, and every chrome-view consumption path SHALL retain a "no skin wired" fallback that matches the pre-skinning constant for that surface.

### Requirement 10: Hot Reload for `.wamp`

**User Story:** As a skin author, I want edits to a `.wamp` file to refresh Holoscape's chrome within 200 ms so that I can iterate without restarts, matching the hot-reload experience for directory-layout skins.

#### Acceptance Criteria

1. WHEN the active skin is a `.wamp` bundle, THE Holoscape SHALL install an FSEventStream watcher on the bundle file's parent directory, filtered to events whose path matches the bundle.
2. WHEN the watcher fires, THE Holoscape SHALL debounce events on a 200 ms trailing edge before re-running the reload pipeline.
3. WHEN re-running reload for a `.wamp` bundle, THE Holoscape SHALL recompute the SHA-256, re-unzip to a new `Cache_Root` subdirectory if the hash changed, and rebuild the `Skin_Context` via `loadComposite(named:)`.
4. IF the bundle's hash has not changed since the last load, THEN THE Holoscape SHALL skip the unzip and rebuild and keep the current `Skin_Context`.
5. IF the re-unzip or rebuild fails, THEN THE Holoscape SHALL keep the previous `Skin_Context` and previous `Skin_Font_Bundle`, log the error, and continue.
6. THE Holoscape SHALL complete the watcher-event-to-chrome-update round trip within 200 ms on Apple Silicon for a bundle under 1 MB.

### Requirement 11: Density Mode Interaction

**User Story:** As Erik, I want Amplify to respect the existing density modes so that I can still drop to a bare terminal when I want focus and keep the shape-and-sprite experience when I want atmosphere.

#### Acceptance Criteria

1. WHILE `DensityMode` is `.off`, THE Holoscape SHALL bypass every Amplify code path (shape masks, sprite slicing, drag regions, FSEventStream watchers on `.wamp`, font registration), render the pre-skinning titled/resizable window, and apply the built-in default `Skin_Context`.
2. WHILE `DensityMode` is `.minimal`, THE Holoscape SHALL apply shape masks and click-through but render all sprite fills as stretched full-sheet images (Requirement 5.6) and suppress state-variant animations.
3. WHILE `DensityMode` is `.full`, THE Holoscape SHALL apply every Amplify feature (shape masks, sprite slicing with state transitions, drag regions, font registration, border / corner / shadow, animations).
4. WHEN `DensityMode` transitions from `.off` to `.minimal` or `.full`, THE Holoscape SHALL reconstruct the window with the correct style mask and reapply the active skin from its cached `LoadedSkin`.

### Requirement 12: Security and Sandboxing

**User Story:** As Erik, I want a malicious `.wamp` bundle to be rejected at unzip time so that a community skin cannot read files outside its own cache directory or blow up the disk.

#### Acceptance Criteria

1. THE Holoscape SHALL reject any `Wamp_Bundle` entry whose path after normalization contains `..`, starts with `/`, or whose resolved symlink target lies outside the bundle's `Cache_Root` subdirectory.
2. THE Holoscape SHALL reject any `Wamp_Bundle` whose total uncompressed size exceeds 50 MB or whose individual asset exceeds 50 MB (Requirement 1.4).
3. THE Holoscape SHALL apply the `Zip_Sandbox` to both `skin.json`, `regions.json`, every `assets/*.png`, every `assets/*.ninepatch.json`, and every `fonts/*.{ttf,otf}` entry before any file-system write.
4. IF a `Wamp_Bundle` contains an entry with an unrecognized extension AND that entry is not referenced by the manifest, THEN THE Holoscape SHALL skip the entry silently.
5. THE Holoscape SHALL log every `Zip_Sandbox` rejection with the offending path, the violation reason, and the bundle name.
6. THE Holoscape SHALL never execute code from a `Wamp_Bundle` — bundles are strictly declarative (manifests, PNG assets, font files).
7. THE Holoscape SHALL resolve `NSWindow` shape polygons only within the content-view coordinate space; polygons with any vertex outside `[-bounds.width, 2 * bounds.width] × [-bounds.height, 2 * bounds.height]` are rejected per Requirement 2.4.

### Requirement 13: Graceful Degradation

**User Story:** As Erik, I want a broken skin to fall back to working chrome rather than brick Holoscape so that an asset mismatch or corrupt file never costs me a launch.

#### Acceptance Criteria

1. IF `skin.json` is malformed, THEN THE Holoscape SHALL drop the skin from the picker, log the parse error, and continue with the previously-active skin.
2. IF `regions.json` is malformed OR `windowShape` validation rejects it, THEN THE Holoscape SHALL apply every other skin feature (fills, fonts, borders, shadows) and revert to a rectangular window, showing a banner at the top of the window for 5 seconds reading "Skin <name>: invalid window shape, using rectangle".
3. IF a referenced font file is missing or fails to register, THEN THE Holoscape SHALL apply every other skin feature, fall back to the system font for affected labels, and log one warning per missing font file.
4. IF a referenced sprite-sheet image is missing, THEN THE Holoscape SHALL fall back to the surface's color fill (or the built-in default color) and log a warning naming the missing path.
5. IF a `Drag_Region_Descriptor` is malformed (fewer than 3 vertices, non-numeric coordinates), THEN THE Holoscape SHALL drop the offending descriptor, apply the remaining valid descriptors, and log a warning naming the offending index.
6. THE Holoscape SHALL surface malformed-skin banner notifications with VoiceOver-readable text and respect Reduce Motion by skipping the banner's fade animation.

### Requirement 14: Performance

**User Story:** As Erik, I want Amplify to not slow down Holoscape's launch or idle cost so that chrome skinning is never the reason my terminal feels sluggish.

#### Acceptance Criteria

1. THE Holoscape SHALL complete a `.wamp` cold-load (read bundle, verify hash, unzip, parse manifest, load images, register fonts, build `Skin_Context`, reconstruct window) in under 500 milliseconds on Apple Silicon for a bundle under 1 MB.
2. THE Holoscape SHALL complete a `.wamp` warm-load (hash matches cache, no re-unzip) in under 150 milliseconds.
3. WHILE a shaped window is active, THE Holoscape SHALL not incur more than 5% CPU over the rectangular-window baseline during an idle second with no terminal activity.
4. WHILE `DensityMode` is `.off`, THE Holoscape SHALL consume zero Amplify-related CPU — no FSEventStream watcher active, no cache read, no sprite slice cache populated.
5. THE Holoscape SHALL evaluate the `Hit_Region_Sampler` in constant or near-constant time per point for polygon counts up to 64 vertices (Requirement 3.4).

### Requirement 15: Accessibility

**User Story:** As a user with accessibility needs, I want shaped and stylized skins to honor macOS accessibility preferences so that visual effects never override the system settings.

#### Acceptance Criteria

1. WHEN the user's Reduce Motion preference is enabled, THE Holoscape SHALL omit the fade transition on shape swap (Requirement 2.7) and omit any fade on the malformed-skin banner (Requirement 13.6).
2. WHEN the user's Reduce Transparency preference is enabled, THE Holoscape SHALL render masked-out regions opaque system-gray instead of fully transparent (Requirement 2.6).
3. WHEN the user's Increase Contrast preference is enabled, THE Holoscape SHALL override the Reader Mode skin font to retain SF Mono 14pt (Requirement 8.6).
4. THE Holoscape SHALL preserve `NSAccessibility` labels on every chrome view regardless of the active skin — sprite buttons inherit the code-provided `accessibilityLabel` string.
5. THE Holoscape SHALL log a HIG violation warning at skin-load time for every declared `Drag_Region_Descriptor` polygon whose bounding box is under 44 × 44 points (Requirement 4.5).

### Requirement 16: Reference Skin — Holoscape Classic

**User Story:** As Erik, I want one bundled Amplify-format reference skin that exercises every Amplify feature so that the engine has a working example and so that dogfood can validate "this is Winamp-class" subjectively.

#### Acceptance Criteria

1. THE Holoscape SHALL ship a reference skin named `HoloscapeClassic` inside the app bundle's `Resources/Skins/` directory as a `.wamp` bundle.
2. THE `HoloscapeClassic` skin SHALL declare a non-rectangular `Window_Shape_Descriptor` with polygons.
3. THE `HoloscapeClassic` skin SHALL include at least one sprite-sheet `Fill_Descriptor` with `normal`, `hover`, and `pressed` cells mapped.
4. THE `HoloscapeClassic` skin SHALL include at least one `Drag_Region_Descriptor`.
5. THE `HoloscapeClassic` skin SHALL include a `fonts/` directory with one TTF referenced by a chrome surface's `Font_Descriptor`.
6. THE `HoloscapeClassic` skin SHALL include `border`, `corner`, and `shadow` on at least one chrome surface.
7. THE Holoscape SHALL include `HoloscapeSynthwave` repackaged as `HoloscapeSynthwave.wamp` in the app bundle to validate backward-compat across the bundle path.

### Requirement 17: Format Documentation

**User Story:** As a skin author, I want a single documented specification of the `.wamp` format so that I can author a skin without reading the engine source code.

#### Acceptance Criteria

1. THE Holoscape project SHALL publish a `docs/amplify-format.md` document covering the `.wamp` bundle layout, every Amplify manifest field with example JSON, the `Window_Shape_Descriptor` coordinate system, the `Sprite_Descriptor` state map, the `Drag_Region_Descriptor` semantics, and the full expanded `Surface_Key` catalog.
2. THE `docs/amplify-format.md` document SHALL include an illustrated example using `HoloscapeClassic` as the worked example.
3. THE `docs/amplify-format.md` document SHALL enumerate every failure mode from Requirement 13 with the resulting user-visible behavior.
4. THE Holoscape project SHALL update `docs/amplify-format.md` in the same PR as any Amplify manifest schema change.
