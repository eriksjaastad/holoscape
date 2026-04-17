# Requirements Document: Chrome Skinning System

## Introduction

Holoscape is a macOS terminal application built with Swift and AppKit that hosts shell, agent, SSH, and group chat sessions in a tabbed interface. The current UI chrome — tab bar, sidebar, input box, window background, and status indicators — is rendered with 32 hardcoded RGB color constants spread across 6 view files (`TabBarView`, `SidebarView`, `InputBoxView`, `SessionLauncherView`, `TerminalContainerView`, `SplitPaneView`). A shallow v1 skin system exists (`SkinDefinition` + `SkinEngine`) that loads `skin.json` from `~/.holoscape/skins/<name>/` but only applies ANSI terminal colors — the chrome views ignore it entirely.

The Chrome Skinning System replaces these hardcoded colors with a runtime-resolved `SkinContext` that reads visual properties from a v2 skin manifest. Skin manifests declare fills (color, image, gradient), borders, corners, shadows, fonts, animations, and state-reactive variants for every chrome surface. Skins are distributed as `.hsk` archives (renamed ZIP files containing `skin.json` + `assets/`). The system adds four independently collapsible chrome regions, three density modes (full/minimal/off), a Reader Mode floating pane for reading terminal output over a dimmed skin, and hot reload via filesystem watching.

The target platform is macOS 15+ (Apple Silicon). The system composes cleanly alongside the existing Metal shader pipeline — shaders process terminal content inside the viewport; chrome skinning handles everything outside it.

## Glossary

- **Animation_Engine**: The subsystem that translates surface descriptor `animation` fields into `CABasicAnimation` or `CASpringAnimation` instances, driven by state transitions
- **Chrome_Region**: One of four independently collapsible areas of the window chrome: top, right, bottom, left. Each region can be shown or hidden at runtime
- **Chrome_Surface**: A named UI element whose visual appearance is controlled by the skin manifest. The 23 surfaces are cataloged in `docs/skins/06-chrome-skinning.md` §6 and correspond to existing AppKit views
- **Density_Mode**: One of three runtime modes controlling skin visibility: Full (all regions, animations), Minimal (thin borders, no animations), Off (bare terminal, zero overhead)
- **HSK_Archive**: The skin distribution format — a renamed ZIP file containing `skin.json` (v2 manifest), `assets/` (PNGs, ninepatch sidecars, fonts), and optionally `shaders/` (GLSL files). File extension: `.hsk`
- **Ninepatch**: An image scaling technique where the image is divided into 9 regions: 4 corners (fixed size), 4 edges (stretch in one direction), 1 center (stretch in both). Described by a sidecar JSON file (`*.ninepatch.json`) alongside the source PNG
- **Reader_Mode**: A minimal floating `NSPanel` that displays the current terminal's scrollback as plain text over a dimmed and animation-paused Holoscape window
- **Reactive_Uniform_Snapshot**: A lock-free atomic snapshot of agent state, command lifecycle, channel state, and notification state, shared between the shader layer and the chrome layer as a single source of truth. Interface defined in `docs/skins/05-reactive-uniforms.md` §6.2; not yet implemented in code
- **Skin_Context**: A `@MainActor` runtime object built from the applied skin manifest. Holds resolved `Resolved_Surface` values for every `Surface_Key`. Chrome views query it to determine their visual appearance
- **Skin_Definition_V1**: The existing `SkinDefinition` struct (`Models/SkinDefinition.swift`) with 10 optional color/image fields. V1 skins continue to load and render correctly under the v2 system
- **Skin_Definition_V2**: The extended manifest format adding an optional `surfaces` dictionary alongside v1 fields. Each entry describes a `Chrome_Surface` with fill, border, corner, padding, shadow, font, text, animation, and state variant properties
- **Skin_Engine**: The existing service (`Services/SkinEngine.swift`) that discovers and loads skins from `~/.holoscape/skins/<name>/`. Extended in v2 to parse the `surfaces` dictionary and build `Skin_Context`
- **State_Match_Expression**: A JSON object in the skin manifest that evaluates against the current `Reactive_Uniform_Snapshot` to determine which state variant applies to a surface. Supports `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte` operators
- **Surface_Descriptor**: A JSON object defining the visual properties of a `Chrome_Surface`: fill, border, corner, padding, shadow, font, text, animation, and states
- **Surface_Key**: A compile-time enum in Swift whose cases correspond to the 23 chrome surfaces (e.g., `.tabBarContainer`, `.sidebarRowActive`, `.inputBoxContainer`). Views reference surfaces by enum case, not string

## Requirements

### Requirement 1: Skin Format and Loading

**User Story:** As Erik, I want to install a skin by dropping an `.hsk` file into a folder, so that I can change Holoscape's entire visual appearance without editing code.

#### Acceptance Criteria

1. WHEN an HSK_Archive is placed in `~/.holoscape/skins/<name>/` (unzipped) or loaded as a `.hsk` file, THE Holoscape SHALL parse the `skin.json` manifest and make the skin available in the Appearance Settings skin picker.
2. THE Holoscape SHALL support Skin_Definition_V1 manifests (10 optional color/image fields) without modification — all v1 fields retain their existing names, types, and semantics.
3. THE Holoscape SHALL support Skin_Definition_V2 manifests containing an optional `surfaces` dictionary alongside v1 fields.
4. IF a skin manifest contains both v1 fields and a v2 `surfaces` dictionary, THEN THE Holoscape SHALL apply v2 surfaces for any Chrome_Surface that has a v2 entry, falling back to v1 fields for surfaces without v2 entries.
5. IF a skin manifest fails to parse (invalid JSON, unknown fields, malformed values), THEN THE Holoscape SHALL log the error, skip the skin, and continue with the previously loaded skin or built-in defaults.
6. THE Holoscape SHALL reject asset paths in the manifest that contain `..` traversal, absolute paths, or HTTP URLs.
7. THE Holoscape SHALL load all skin image assets into memory at skin-apply time and cache them per-skin in the Skin_Context.

### Requirement 2: Surface Descriptor Model

**User Story:** As Erik, I want each chrome element to support colors, images, gradients, borders, corners, shadows, and fonts, so that skins can create rich visual effects beyond simple color swaps.

#### Acceptance Criteria

1. THE Holoscape SHALL support three fill variants for any Chrome_Surface: `color` (hex string), `image` (PNG path with tile mode), and `gradient` (direction + color stops).
2. THE Holoscape SHALL support image tile modes: `stretch` (resize to surface bounds), `tile` (repeat), and `ninepatch` (9-slice scaling from sidecar).
3. WHEN a fill references an image with a Ninepatch sidecar (`*.ninepatch.json`), THE Holoscape SHALL use the sidecar's `stretchX` and `stretchY` ranges to render the image with fixed corners and stretchable edges.
4. THE Holoscape SHALL support `border` (color + width), `corner` (radius as single value or 4-tuple `[tl, tr, br, bl]`), `shadow` (color, opacity, blur, offset), and `padding` (top, right, bottom, left) properties on any Chrome_Surface.
5. THE Holoscape SHALL support gradient fills with `vertical` and `horizontal` directions and 2+ color stops with offset values between 0.0 and 1.0.
6. THE Holoscape SHALL render all surface properties via `CALayer` compositing — fills via `backgroundColor` or `contents`, borders via `borderColor`/`borderWidth`, corners via `cornerRadius`, shadows via `shadowColor`/`shadowRadius`/`shadowOffset`.

### Requirement 3: SkinContext and Surface Resolution

**User Story:** As Erik, I want chrome views to read their appearance from the skin at runtime, so that changing the skin immediately changes the UI without recompiling.

#### Acceptance Criteria

1. THE Holoscape SHALL provide a Skin_Context object that resolves a Surface_Key to a `ResolvedSurface` containing computed fill, border, corner, padding, shadow, font, text, and animation values.
2. THE Holoscape SHALL inject the Skin_Context into every chrome view at construction time via MainWindowController.
3. WHEN a Chrome_Surface has no v2 entry in the manifest, THE Holoscape SHALL fall back to the built-in default values (the current hardcoded colors).
4. THE Holoscape SHALL use a Surface_Key enum with compile-time cases for all 23 surfaces, ensuring rename drift is caught by the compiler.
5. WHEN the active skin changes (via settings picker or hot reload), THE Holoscape SHALL rebuild the Skin_Context and notify all chrome views to re-layout within 200ms.
6. THE Holoscape SHALL delete all 32 hardcoded `static let` color constants from chrome view files and replace them with Skin_Context lookups.

### Requirement 4: Tab Bar Skinning

**User Story:** As Erik, I want the tab bar to transform visually with the skin — riveted metal, neon strips, whatever I design — not just color tints.

#### Acceptance Criteria

1. THE Holoscape SHALL resolve the `tabBar.container` surface for the tab bar background fill, border, corner, and padding.
2. THE Holoscape SHALL resolve `tabBar.tab.active`, `tabBar.tab.normal`, `tabBar.tab.idle`, and `tabBar.tab.permission` surfaces for each tab state.
3. WHEN a tab transitions between states (normal → active, normal → idle, normal → permission), THE Holoscape SHALL animate the fill transition using the surface's `animation` descriptor.
4. THE Holoscape SHALL resolve `tabBar.tab.unreadMarker` for the unread indicator, allowing skins to replace the default `●` bullet with a custom fill or image.
5. THE Holoscape SHALL apply skin-defined `font` and `text` properties to tab labels, including custom font families shipped with the skin.

### Requirement 5: Sidebar Skinning

**User Story:** As Erik, I want the sidebar to completely transform — glowing dots, custom shapes, futuristic indicators — not just background color changes.

#### Acceptance Criteria

1. THE Holoscape SHALL resolve `sidebar.container` for the sidebar background fill and padding.
2. THE Holoscape SHALL resolve `sidebar.row.normal`, `sidebar.row.selected`, and `sidebar.row.hover` for sidebar entry states.
3. THE Holoscape SHALL resolve `sidebar.row.indicator` for tab status indicators, allowing skins to replace the default colored dots with custom fills, shapes, or images.
4. THE Holoscape SHALL support three indicator states driven by channel status: active (default: green), connecting (default: yellow), and disconnected (default: red). Default values are system colors; skins override them.
5. THE Holoscape SHALL resolve `sidebar.sectionHeader` for section divider appearance.
6. THE Holoscape SHALL maintain scroll behavior regardless of indicator design — the sidebar is always scrollable when entries exceed the visible area.
7. WHEN a sidebar entry gains unread messages, THE Holoscape SHALL animate the entry's surface using the `states` variant matched by `channelUnread >= 1`.

### Requirement 6: Window and Utility Surface Skinning

**User Story:** As Erik, I want the window background, input box, session launcher, and split pane dividers to match the skin, so the entire app feels cohesive.

#### Acceptance Criteria

1. THE Holoscape SHALL resolve `window.background` for the main window background fill.
2. THE Holoscape SHALL resolve `window.titleBar` for the title bar tint, respecting `NSWindow.titlebarAppearsTransparent`.
3. THE Holoscape SHALL resolve `inputBox.container`, `inputBox.field`, and `inputBox.placeholder` for the input area.
4. THE Holoscape SHALL resolve `sessionLauncher.container` and `sessionLauncher.row` for the session launcher dropdown.
5. THE Holoscape SHALL resolve `splitPane.divider` for the split pane divider appearance.
6. THE Holoscape SHALL resolve `terminalContainer.padding` for the terminal viewport padding area.
7. THE Holoscape SHALL resolve `settings.panel` and `dialog.container` for the settings window and dialog chrome.

### Requirement 7: Image Asset Pipeline

**User Story:** As Erik, I want skin images to scale correctly on any monitor without becoming blurry or distorted, so that skins look sharp on both laptops and large displays.

#### Acceptance Criteria

1. THE Holoscape SHALL load PNG images referenced in the manifest from the skin's `assets/` directory via `NSImage(contentsOfFile:)`.
2. THE Holoscape SHALL apply 9-slice scaling using `CALayer.contentsCenter` when a Ninepatch sidecar is present, keeping corners at their original pixel size and stretching edges.
3. THE Holoscape SHALL set `CALayer.contentsScale` to `window.backingScaleFactor` for all skin image layers, ensuring sharp rendering on Retina displays.
4. THE Holoscape SHALL cache all loaded images per-skin in the Skin_Context and release them when the skin is unloaded.
5. IF a referenced image file does not exist at the resolved path, THEN THE Holoscape SHALL log a warning and fall back to the surface's color fill or the built-in default.

### Requirement 8: Font Loading

**User Story:** As Erik, I want skins to ship their own fonts so I can use pixel fonts, retro typefaces, or custom typography without installing them system-wide.

#### Acceptance Criteria

1. WHEN a skin manifest references a `font.family` that is not installed system-wide, THE Holoscape SHALL search for `.otf` or `.ttf` files in the skin's `assets/fonts/` directory.
2. THE Holoscape SHALL register skin fonts using `CTFontManagerRegisterFontsForURL` with process scope (not persistent — fonts are not added to the user's Font Book).
3. WHEN a skin is unloaded, THE Holoscape SHALL deregister its fonts using `CTFontManagerUnregisterFontsForURL`.
4. IF a referenced font file is missing or corrupt, THEN THE Holoscape SHALL log a warning and fall back to the system default font (SF Mono).
5. THE Holoscape SHALL apply skin-defined fonts to tab labels, sidebar entries, and the input box placeholder text.

### Requirement 9: Collapsible Chrome Regions

**User Story:** As Erik, I want to collapse chrome regions independently so I can have full graphics on my big monitor but a compact layout on my laptop.

#### Acceptance Criteria

1. THE Holoscape SHALL define four independently collapsible Chrome_Regions: top, right, bottom, and left.
2. WHEN a Chrome_Region is collapsed, THE Holoscape SHALL animate the region out with a 200ms ease-out slide and expand the terminal viewport to fill the freed space.
3. WHEN a Chrome_Region is expanded, THE Holoscape SHALL animate the region in with a 200ms ease-out slide and shrink the terminal viewport accordingly.
4. THE Holoscape SHALL persist the collapsed/expanded state of each Chrome_Region across app restarts via HoloscapeConfig.
5. IF a skin manifest does not provide assets for a Chrome_Region, THEN THE Holoscape SHALL treat that region as collapsed by default.
6. THE Holoscape SHALL provide View menu items for toggling each Chrome_Region's visibility.

### Requirement 10: Density Modes

**User Story:** As Erik, I want to switch between full, minimal, and off skin modes so I can go from "wow" to "focus" to "bare terminal" with one action.

#### Acceptance Criteria

1. THE Holoscape SHALL support three Density_Modes: Full (all regions visible, animations running), Minimal (thin borders, no animations, reduced visual footprint), and Off (bare terminal, no skin rendering).
2. WHEN switching from one Density_Mode to another, THE Holoscape SHALL complete the transition within 200ms with no visual glitch.
3. WHEN Density_Mode is Off, THE Holoscape SHALL render identically to the pre-skinning build with zero performance overhead — no Skin_Context queries, no CALayer image compositing, no animation timers.
4. WHEN Density_Mode is Minimal, THE Holoscape SHALL use only `color` fills from the manifest (ignoring image and gradient fills) and disable all `animation` descriptors.
5. THE Holoscape SHALL persist the current Density_Mode across app restarts.
6. THE Holoscape SHALL provide a menu item and/or Appearance Settings control for switching Density_Mode.

### Requirement 11: Reader Mode

**User Story:** As Erik, I want a minimal reader pane that floats over the dimmed skin so I can read long terminal output without visual noise, then dismiss it and return to the full skin experience.

#### Acceptance Criteria

1. WHEN Reader_Mode is activated, THE Holoscape SHALL display a floating NSPanel containing the current terminal's full scrollback as plain text with ANSI codes stripped.
2. WHEN Reader_Mode is activated, THE Holoscape SHALL dim the main Holoscape window (reduced alpha, desaturated colors) and pause all skin animations.
3. THE Holoscape SHALL render the Reader_Mode panel as draggable, resizable, and scrollable, with no navigation controls, no toolbar, and no status bar — only text.
4. WHILE Reader_Mode is active, THE Holoscape SHALL maintain console input focus in the main window so Erik can continue typing (speech-to-text) while reading.
5. WHEN Reader_Mode is dismissed, THE Holoscape SHALL restore the main window to full brightness, re-saturate colors, and resume skin animations within 100ms.
6. THE Holoscape SHALL render the Reader_Mode panel with the system default monospace font at a readable size (14pt minimum), regardless of the active skin's font settings.
7. THE Holoscape SHALL provide a menu item and keyboard shortcut for toggling Reader_Mode.

### Requirement 12: State Reactivity

**User Story:** As Erik, I want the chrome to react to agent state changes — the tab glows red on error, the sidebar pulses when thinking — so the skin feels alive.

#### Acceptance Criteria

1. THE Holoscape SHALL evaluate State_Match_Expressions in the manifest's `states` array against the current Reactive_Uniform_Snapshot on every state transition.
2. THE Holoscape SHALL support match keys: `agentState`, `previousAgentState`, `commandState`, `previousCommandState`, `lastCommandExitCode`, `channelId`, `channelIsActive`, `channelUnread`, `notificationKind`, and `timeSince`.
3. THE Holoscape SHALL support match operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`. A bare scalar value is shorthand for `$eq`.
4. WHEN multiple `states` entries match, THE Holoscape SHALL apply them in array order — last matching state wins for each property (CSS-cascade semantics).
5. WHEN a state transition fires, THE Holoscape SHALL animate all affected surfaces simultaneously from the same timestamp for a cohesive visual response.
6. THE Holoscape SHALL share the same Reactive_Uniform_Snapshot instance between the shader layer and the chrome layer — no separate event bus.

### Requirement 13: Animation Engine

**User Story:** As Erik, I want skin transitions to feel smooth and polished — tabs fade, sidebars pulse, indicators glow — not just snap between states.

#### Acceptance Criteria

1. THE Holoscape SHALL provide an Animation_Engine that translates surface `animation` descriptors into `CABasicAnimation` or `CASpringAnimation` instances.
2. THE Holoscape SHALL support animation curves: `linear`, `easeIn`, `easeOut`, `easeInOut`, and `spring`.
3. THE Holoscape SHALL start a `CADisplayLink` when any surface has an active animation and stop it when all animations complete — idle chrome draws zero frames per second.
4. THE Holoscape SHALL support per-property animation overrides (e.g., fill animates at 350ms ease-out while corner.radius animates at 150ms linear).
5. WHEN Density_Mode is Minimal or Off, THE Holoscape SHALL suppress all animations — state changes apply instantly.

### Requirement 14: Hot Reload

**User Story:** As Erik, I want to edit a skin's JSON or swap an image and see the change live in Holoscape without restarting the app.

#### Acceptance Criteria

1. THE Holoscape SHALL watch the active skin's directory using `FSEventStream` for file changes.
2. WHEN a file change is detected, THE Holoscape SHALL debounce for 200ms, then reload `skin.json`, re-resolve the Skin_Context, re-register fonts, and post a `SkinDidChange` notification.
3. WHEN a `SkinDidChange` notification is posted, THE Holoscape SHALL cause all chrome views to re-layout and pick up new surface values.
4. IF the reloaded manifest is invalid, THEN THE Holoscape SHALL log the error and keep the previous valid Skin_Context active.
5. THE Holoscape SHALL release cached images for the previous skin version and load new images from the updated manifest.

### Requirement 15: Performance and Zero Overhead

**User Story:** As Erik, I want Holoscape to perform identically when skins are off, so the skinning system never degrades my terminal experience.

#### Acceptance Criteria

1. WHEN no skin is loaded and Density_Mode is Off, THE Holoscape SHALL not allocate Skin_Context, not run FSEventStream watchers, not create animation timers, and not perform CALayer image compositing for chrome surfaces.
2. WHEN a skin is active, THE Holoscape SHALL perform chrome redraws only on state transitions — not per-frame.
3. THE Holoscape SHALL load all skin assets synchronously on the main thread at skin-apply time. Assets total for a single skin SHALL remain under 10MB.
4. WHILE no surface animation is active, THE Holoscape SHALL not run any CADisplayLink or timer for chrome rendering.
5. THE Holoscape SHALL complete skin switching (full Skin_Context rebuild + view re-layout) within 200ms.

### Requirement 16: Reference Skin

**User Story:** As Erik, I want a built-in demo skin that shows off every skinning feature, so I can see what's possible and use it as a template for my own designs.

#### Acceptance Criteria

1. THE Holoscape SHALL ship a built-in reference skin ("Holoscape Classic Winamp") that exercises: image fills with ninepatch, gradient fills, custom font from skin assets, state-reactive tab and sidebar surfaces, and animation on agent state transitions.
2. THE Holoscape SHALL make the reference skin selectable from the Appearance Settings skin picker without any manual file installation.
3. THE Holoscape SHALL render the reference skin correctly at both 1x and 2x display scales.
4. THE Holoscape SHALL include in the reference skin a `skin.json` manifest that serves as a template for hand-building new skins — all v2 Surface_Descriptor features used at least once.
5. THE Holoscape SHALL include the reference skin in the app bundle as a processed resource.
