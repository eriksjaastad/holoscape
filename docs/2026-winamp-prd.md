# PRD: 2026 Winamp skinning for Holoscape (#6030)

Status: current implementation PRD for the skinning track.

## Goal

Holoscape should support a Winamp-class visual shell without compromising its role as a reliable terminal. A skin can make the app feel like a piece of hardware — shaped chrome, stateful buttons, custom typography, shadows, and optional decorative sub-windows — while the terminal/session/core state remains self-contained and usable when skins are off.

This PRD is additive to the current stack. It does not replace `SurfaceKey`, `SurfaceDescriptor`, `SkinContext`, `SkinEngine`, `ChromeDescriptor`, `ChromeHostView`, or `InteriorView`.

## Product rules

1. Terminal correctness wins over skin fidelity.
2. Skins are declarative manifests plus local assets. No scripts, plugins, network fetches, or executable code.
3. Turning skins off leaves terminal/session behavior unchanged.
4. Skin failures are loud and recoverable: reject unsafe assets, keep the previous working skin when possible, and show/banner/log the reason.
5. The public skin authoring contract must stay smaller than the internal art direction. Erik can make wild skins; the engine should expose bounded primitives.

## Existing foundation to preserve

- `SurfaceKey` already catalogs the skinnable chrome surfaces and the newer interactive/window-level cases.
- `SurfaceDescriptor` and related fill/border/corner/shadow/font descriptors are the manifest-level base.
- `SkinEngine.loadComposite(named:)` is the authoritative load transaction for directory and `.wamp` skins.
- `ChromeDescriptor` + `ChromeBakePipeline` support baked and composed chrome.
- `ChromeHostView` owns non-interactive alpha-aware chrome pixels and animated overlays.
- `InteriorView` owns app content inside `interiorRect` so terminal/sidebar/tab content does not participate in the shaped-window alpha path.
- Existing font registration, asset sandboxing, hot reload, validation, density mode, reduce-motion hooks, and animation renderers remain the reliability substrate.

## Scope areas and acceptance criteria

### 1. Shaped windows

**User outcome:** a skin can define a non-rectangular-looking app shell with real transparent cutouts around the terminal interior.

**Implementation direction:** keep the current `ChromeHostView`/`InteriorView` architecture. The base chrome image alpha is the visual silhouette; shape polygons continue to drive validation, click-through, and drag logic where needed.

**Acceptance:**

- A baked chrome skin can declare `chrome.image`, `chrome.interiorRect`, and optional shape/drag polygons.
- App content is reparented under `InteriorView`, not masked by the whole content view.
- Transparent chrome pixels reveal the desktop or windows behind Holoscape.
- Switching between a rectangular skin and shaped skin reconstructs the window without losing the core content view tree.
- If shape validation fails, the skin falls back with a visible warning instead of producing an unsafe partially-shaped window.

### 2. Per-button art and interaction states

**User outcome:** tabs, sidebar rows, launcher buttons, and panel controls can look like real skinned controls instead of colored rectangles.

**Implementation direction:** use existing/new `SurfaceKey` cases for normal, hover, pressed, active, selected, permission, idle, and unread states. Prefer sprite-sheet metadata on image fills for compact authoring, with explicit state keys where a surface needs separate layout or semantics.

**Acceptance:**

- Tab, sidebar, launcher, and reader-panel controls can resolve state-specific surface descriptors.
- Hover and pressed state changes update visual art without touching terminal focus or input routing.
- Missing state art falls back to normal/active/default descriptors deterministically.
- Sprite slicing is bounded by manifest validation; out-of-range cells disable that surface or layer with a clear warning.
- Density `.minimal` can collapse animated/state-heavy art to a static readable version.

### 3. Click regions and drag regions

**User outcome:** visual cutouts behave like cutouts, and the user can drag the window from skin-authored handles.

**Implementation direction:** keep hit-testing separate from visual rendering. Use shape/region descriptors for click-through and drag handles; do not infer all behavior from arbitrary art pixels at runtime unless a future card explicitly adds alpha sampling.

**Acceptance:**

- Points outside the accepted shape region do not steal mouse events.
- Declared drag regions call normal AppKit window dragging behavior.
- Drag regions cannot overlap terminal text/input areas unless the manifest marks them as non-interactive chrome.
- Region coordinates are documented in chrome logical coordinates and tested against `interiorRect`.
- Region validation rejects impossible polygons, out-of-bounds regions, and self-intersections when detectable.

### 4. Fonts and typography

**User outcome:** a skin can carry its own visual identity through tab labels, sidebar labels, launcher rows, status text, and reader chrome without requiring system-wide font installation.

**Implementation direction:** continue using process-scoped skin font registration in `SkinEngine`; wire chrome views to resolve fonts through `SkinContext`/resolved surfaces.

**Acceptance:**

- `.ttf` and `.otf` files inside a skin bundle can be registered for the active skin and deregistered on unload/switch.
- `TabBarView`, `SidebarView`, `InputBoxView`, `SessionLauncherView`, settings/dialog chrome, and reader-panel chrome have defined font resolution behavior.
- Missing/corrupt fonts fall back to system fonts with a warning; they do not abort an otherwise valid skin unless the manifest marks the font as required.
- Font registration remains symmetric in tests so switching skins does not leak process-scoped fonts indefinitely.

### 5. Shadow, border, corner, and depth

**User outcome:** skins can create bevels, glow, inset panels, rounded/pill controls, and hardware-like depth.

**Implementation direction:** make every migrated chrome view consume the existing descriptor model rather than inventing one-off styling properties.

**Acceptance:**

- Border, corner, and shadow descriptors are applied consistently to skinnable chrome views.
- AppKit window shadow behavior is documented separately from per-surface shadows.
- Reduce Transparency has a deterministic fallback path for translucent depth effects.
- Shadow/border rendering cannot expand interactive hit regions beyond the declared view or chrome region.
- Invalid colors, negative widths, and impossible radii are rejected or clamped with explicit validation rules.

### 6. Sub-windows and auxiliary panels

**User outcome:** Holoscape can support Winamp-like auxiliary panels without pretending terminal skins are a multi-window media player.

**Implementation direction:** start with bounded auxiliary surfaces such as Reader Mode, status/instrument panels, and decorative non-interactive subdevices inside the main chrome. Detachable/persistent independent windows are follow-up work only after the main window contract is stable.

**Acceptance:**

- Reader Mode panel chrome has documented surface keys and fallbacks.
- Decorative subdevices in the main shell are non-interactive by default and live under `ChromeHostView` animated layers.
- Any future interactive auxiliary panel has an explicit owner/controller, focus policy, persistence policy, and keyboard-navigation behavior before implementation.
- Closing or disabling an auxiliary panel never affects the underlying terminal session.
- No Project Tracker, message-ledger, sync, or external workflow semantics are introduced as core skin dependencies.

## Natural PR order

1. **Shaped-window contract hardening** — document/lock the `ChromeHostView` + `InteriorView` invariants; expand tests for rectangular↔shaped transitions and validation fallback.
2. **Per-button art wiring** — migrate tab/sidebar/launcher/reader controls to state-specific `SurfaceKey` resolution and sprite fallback rules.
3. **Click and drag regions** — finish validation and hit-test tests around shape, drag handles, and `interiorRect` safety.
4. **Fonts** — consume registered skin fonts across chrome views and preserve registration symmetry.
5. **Shadow/border/corner depth** — make descriptor application consistent and test Reduce Transparency/minimal-density behavior.
6. **Sub-windows/panels** — make Reader Mode the first skinned auxiliary panel; only then consider additional panels.

## Non-goals

- Art commissioning or choosing the final visual taste.
- Winamp `.wsz` import.
- Maki/Lua/JavaScript or any executable skin scripting.
- Skin marketplace, remote downloads, or community publishing infrastructure.
- Hardwiring Project Tracker or any external integration into skin/core terminal behavior.
- Adding new AI-builder/product breadth before the core skin/runtime contracts are stable.

## Verification plan

- Unit tests for manifest decoding, validation, path sandboxing, sprite-state fallback, shape/drag region validation, and font registration symmetry.
- Controller/view tests for shaped-window reconstruction, `InteriorView` containment, density/reduce-motion forwarding, and hot reload.
- Visual smoke skins: one baked shaped skin, one composed reference skin, one malformed skin fixture, and one minimal/off density path.
- Manual dogfood: switch rectangular↔shaped skins, edit a skin under hot reload, trigger hover/pressed states, toggle Reduce Motion and density modes, and verify terminal input/session state survives throughout.
