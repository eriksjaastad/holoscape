# PNG Chrome PRD — Winamp-class Skinning, Take Two

**Codename**: Chrome (successor to Amplify)
**Status**: proposed, replacing the `CALayer.mask` polygon approach
**Author**: Claude Opus 4.7 + Erik
**Date**: 2026-04-19
**Supersedes**: `docs/amplify-prd.md` (shape + drag-region sections only — chrome skinning surfaces, sprites, fonts, and `.wamp` bundles carry forward unchanged)

---

## 1) Overview

A new architecture for non-rectangular, visually-distinctive Holoscape windows. Instead of using `CALayer.mask` on a borderless `NSWindow`'s content view to clip a polygon shape, the window is a **single PNG with alpha**. The PNG's opaque regions are the visible chrome; its transparent regions are real OS-level window transparency. Every interactive subview (terminal, sidebar, tab bar, buttons) is positioned inside the PNG's opaque region and clipped to it. Hit testing samples the PNG's alpha directly. Dragging uses the PNG's opaque region as the drag surface via `isMovableByWindowBackground`.

This is the architecture Winamp 2.x used in 1998 for `.wsz` skins. Skin authors already know how to think in this model. It sidesteps the CA masking problem that stopped Amplify v1.

## 2) Goals

- **Actual transparency.** The cut corners of a shaped window reveal the desktop behind, not an opaque dark rectangle.
- **Fun + easy skin authoring.** Authors ship a PNG. Alpha = shape. No polygon arithmetic, no bounding-box math, no coordinate-space debates. The format is a file you open in any image editor.
- **Preserve shipped work.** Sprite sheets (buttons), font consumption, border/corner/shadow on individual chrome surfaces, `.wamp` bundle format, skin picker + hot reload, malformed-skin banner — all carry forward from Amplify v1.
- **First-class fidelity to the Winamp reference.** Goal is "a skin author familiar with `.wsz` can author a `.wamp` and feel at home."
- **Debuggable.** The PNG IS the source of truth. Ship a debug overlay that renders alpha values over the window so authors can see their shape without guessing.

## 3) Non-Goals

- Direct `.wsz` (Winamp) import. Nice-to-have later; not MVP.
- Animated chrome (GIF-based backgrounds). The PNG is static.
- Shaders applied to the chrome itself (the existing Holoscape shader pipeline is orthogonal and continues to run inside the opaque region when active).
- Multi-window semantics (Winamp had EQ + playlist + minibrowser windows). Holoscape is a terminal — one main window plus existing Reader Mode panel.
- Runtime hit-test of complex curved shapes via bezier math. The PNG alpha replaces all of that.

## 4) Target Users

- **Skin authors** porting Winamp `.wsz` skins mentally (or literally in Phase 2) who want "paint a PNG, ship a skin."
- **Holoscape daily drivers** who want a visually distinctive terminal without fighting the engine.
- **Erik** specifically — this is a tool he uses every day, and the chrome needs to not be "meh."

## 5) Problem Statement

Amplify v1 used `CALayer.mask` on the content view to polygon-clip a borderless NSWindow. Live testing (documented in `docs/research/shaped-window-transparency-findings.md`) confirmed:

1. Every documented transparency property is correctly set (`isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, content view layer background nil, frame view layer background nil, mask installed with correct frame).
2. The mask clips drawn content (text, sprites, window borders) correctly.
3. The mask does NOT clip descendant layers' `backgroundColor`. Sidebar + terminal + split-pane layers paint opaque rectangles through the mask.
4. The observed behavior contradicts Apple's Core Animation documentation, and no concrete source (forum post, WWDC talk, open-source code) was found that explains the bypass.

The result: we spent a full evening on four successive speculative fixes plus extensive runtime diagnostics, and still cannot make the cut corners transparent to the desktop. The architecture is fighting us. Skin authoring in this model would require the same fight for every subview the author adds.

## 6) Core Concept

**One PNG, four rules.**

1. **One PNG** — the skin ships `chrome.png`, a single RGBA image at the skin's nominal window size (e.g. 1000×700). Alpha > 0 pixels are the chrome. Alpha == 0 pixels are transparent to the desktop.
2. **The PNG is the window background** — an `NSImageView` (or `CALayer.contents`) renders the PNG filling the entire borderless window. Because the PNG has alpha and the window is `isOpaque = false`, the OS compositor honors the PNG's alpha channel as actual window transparency. No mask needed.
3. **Subviews live in opaque regions** — the manifest declares where the terminal, sidebar, tab bar, etc. are positioned. Authors draw the PNG with their intended layout; the manifest pairs each subview with an `{x, y, width, height}` rect.
4. **Hit testing samples the PNG alpha** — when a mouse event arrives, sample the PNG at the event's content-view point. Alpha ≥ threshold (e.g. 64/255) = opaque chrome, route to the topmost subview at that point. Alpha < threshold = transparent, return `nil` from `hitTest` so the click passes to whatever's behind.

```
┌─────────────────────────────────────────────┐
│ borderless NSWindow (isOpaque = false)      │
│ ┌─────────────────────────────────────────┐ │
│ │ contentView                             │ │
│ │ ┌─────────────────────────────────────┐ │ │
│ │ │ NSImageView (chrome.png, RGBA)      │ │ │
│ │ │   alpha=0 regions → see desktop     │ │ │
│ │ │   alpha=1 regions → visible chrome  │ │ │
│ │ └─────────────────────────────────────┘ │ │
│ │   subviews positioned by manifest:      │ │
│ │   ┌──────┐ ┌──────────────────────────┐ │ │
│ │   │ side │ │ terminal                 │ │ │
│ │   │ bar  │ │                          │ │ │
│ │   │      │ │                          │ │ │
│ │   └──────┘ └──────────────────────────┘ │ │
│ └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## 7) Data Model (MVP)

New/changed descriptor types in `Sources/Holoscape/Models/AmplifyDescriptors.swift`:

```swift
struct ChromeImageDescriptor: Codable, Equatable, Sendable {
    let path: String       // "assets/chrome.png"
    let width: Int         // PNG pixel width (= nominal window width)
    let height: Int        // PNG pixel height
    let hitTestThreshold: UInt8  // 0-255, default 64
}

struct SubviewAnchor: Codable, Equatable, Sendable {
    let role: Role         // terminal | sidebar | tabBar | inputBox | sessionLauncher
    let frame: SkinRect    // { x, y, width, height } in PNG coords

    enum Role: String, Codable, Sendable {
        case terminal, sidebar, tabBar, inputBox, sessionLauncher
    }
}

struct SkinRect: Codable, Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
}
```

Top-level `SkinDefinition` v4 additions:

```swift
struct SkinDefinition {
    // Existing v1/v2/v3 fields unchanged — carry forward.

    // NEW v4 fields:
    let chromeImage: ChromeImageDescriptor?   // Present: PNG-chrome mode. Absent: v2/v3 rect-chrome mode.
    let anchors: [SubviewAnchor]?             // One entry per role. Required when chromeImage present.
    // windowShape retained but deprecated — emits a warning, honored for backward-compat via a CALayer.mask fallback
    // dragRegions retained — now PNG-alpha-relative; existing polygon syntax still works
}
```

**Backward compatibility**: v3 skins without `chromeImage` continue to work exactly as they do today (rectangular or CA-mask polygon, whatever they declared). `chromeImage: present` opts into the new pipeline.

## 8) Functional Requirements

**FR-1 — Chrome PNG renders as window background.** When the manifest declares `chromeImage`, the engine installs the PNG as the window's background view, RGBA honored, window sized to `chromeImage.width × chromeImage.height`.

**FR-2 — Window is fixed-size.** When PNG chrome is active, the window is `contentMinSize == contentMaxSize == PNG dimensions`. `.resizable` stripped from the style mask. Same rule Amplify v1 already ships.

**FR-3 — Alpha = transparency.** Pixels in the PNG with alpha < 1.0 produce commensurate window transparency. Alpha == 0 pixels reveal the desktop behind.

**FR-4 — Subviews honor anchors.** For each `SubviewAnchor`, the engine repositions the corresponding managed subview (terminal, sidebar, etc.) to the declared frame in PNG coordinates. Autoresizing constraints deactivate inside the PNG-chrome path.

**FR-5 — Hit testing samples PNG alpha.** `ShapedContentView.hitTest(point)` samples the PNG at `point`. If alpha < `hitTestThreshold`, return `nil` (click-through). Otherwise delegate to `super.hitTest`.

**FR-6 — Dragging via background.** `window.isMovableByWindowBackground = true` is sufficient because the PNG IS the background — AppKit's "bare background pixel" requirement is satisfied everywhere the PNG is opaque and no subview covers it.

**FR-7 — Sprite buttons, fonts, border/corner/shadow still work.** Inside each subview's declared frame, existing v3 surface descriptors (sprite sheets, fonts, bevels) render exactly as today. Only the window-shape piece changes.

**FR-8 — Hot reload.** Editing the PNG file inside a `.wamp` bundle triggers the same FSEventStream path that already handles manifest changes. The engine re-decodes the PNG, re-installs it, and repositions subviews.

**FR-9 — Debug alpha overlay.** A developer flag (`HOLOSCAPE_PNG_CHROME_DEBUG=1`) overlays a semitransparent false-color rendering of the PNG's alpha channel so authors can see their shape exactly as the hit tester sees it.

**FR-10 — Malformed PNG → graceful fallback.** Missing file, non-RGBA image, or dimension mismatch with declared `width`/`height` produces a `SkinWarningBanner` (Task 21.2 already shipped) and falls back to rectangular rendering with the declared surface fills.

**FR-11 — Accessibility parity.** Reduce Motion, Reduce Transparency, Increase Contrast preferences continue to apply. Under Reduce Transparency, the PNG renders with its alpha channel forced to 1.0 and the transparent regions filled with system gray — no real transparency, but the shape outline is preserved.

## 9) Non-Functional Requirements

- **No hardcoded absolute paths.** Asset paths are relative to the `.wamp` bundle root or the directory-layout skin root.
- **No secrets in code.** Not applicable — no credentials or API keys in the chrome pipeline. Standard.
- **Safe file operations and validation.** PNG load path continues to use the existing `WampBundleLoader` sandbox (size cap, symlink-escape rejection, SHA-keyed cache). PNG decode errors never crash — they produce a logged warning and the fallback in FR-10.
- **Performance.** PNG decode + subview repositioning must complete within the existing 500 ms cold-load budget from Amplify v1. Hit-test alpha sampling must be under 100 µs per point (matches Amplify Req 3.4 for polygon hit testing).
- **Memory.** A 1000×700 RGBA PNG is ~2.7 MB decoded. Cap PNG dimensions at 4096×4096 (44 MB) to stay under the existing 50 MB `.wamp` bundle cap with headroom for other assets.
- **Swift concurrency.** `@MainActor` for the chrome view + image decode integration with the existing `SkinEngine`. No new thread-hopping.

## 10) UX and UI Requirements

- **Authoring flow**: open the PNG template in any image editor (Photoshop, Figma, Pixelmator, even `uv run --with pillow`). Paint the chrome. Save. Edit `skin.json` to declare subview anchors. Hot reload verifies.
- **First-run experience**: the shipped `HoloscapeClassic.wamp` is the worked example. Installed alongside `HoloscapeSynthwave` and AmplifyDemo.
- **Template PNG**: ship `docs/chrome-template.psd` + `docs/chrome-template.png` with the subview frames drawn in semitransparent colored rectangles. Author replaces the rectangles with real chrome art, keeps the frame geometry.
- **Debug overlay**: `HOLOSCAPE_PNG_CHROME_DEBUG=1` shows: PNG alpha as a red-channel overlay, subview anchor rects as green outlines, hit-test threshold line as a single alpha slice. Skin authors toggle while iterating.
- **Accessibility**: Reduce Transparency fallback (opaque-chrome silhouette), Reduce Motion disables any transitions on chrome swap, Increase Contrast keeps shipped defaults over skin values (same as Amplify v1).
- **Error surface**: Req 13.2 banner continues to be the author-facing error surface.

## 11) Success Metrics

- **Shape works.** The cut corners of `HoloscapeClassic` actually reveal the desktop when the window is positioned over another visible window. Erik confirms via visual test.
- **First third-party skin.** Someone (Erik or an external contributor) authors a non-Classic PNG-chrome skin end-to-end using only the format docs and the template. Success = the skin loads and renders correctly without Claude's help.
- **No CA-masking regressions.** Existing v2/v3 skins (HoloscapeSynthwave, AmplifyDemo) continue to render identically. Backward-compat integration tests pass.
- **Time to author.** From blank PNG to working skin < 30 minutes for someone familiar with image editors.
- **Zero transparency-related bug reports** against the MVP after it ships.

## 12) MVP Scope

Ship these, in rough PR order:

1. **Data model** — `ChromeImageDescriptor`, `SubviewAnchor`, `SkinRect`; extend `SkinDefinition` v4.
2. **Chrome view** — `ChromeImageView: NSView` that renders the PNG via `layer.contents` + honors alpha. Installed as contentView's first subview at full bounds.
3. **Hit testing** — `AlphaHitSampler` (already stubbed in the Amplify design). Samples PNG alpha at a given point; returns inside/outside decision. Replaces `HitRegionSampler` when PNG chrome is active.
4. **Subview anchoring** — `MainWindowController.applyChromeAnchors` repositions terminal/sidebar/tabBar/inputBox/sessionLauncher to the declared frames.
5. **Borderless + `.clear` + `hasShadow = false`** — same window setup as Amplify v1 (reuse the existing `ShapedBorderlessWindow` subclass).
6. **Fixed size** — reuse Amplify v1's `contentMinSize == contentMaxSize` logic.
7. **Drag via background** — `window.isMovableByWindowBackground = true`. Drop the `WindowDragOverlay` from Amplify v1 (no longer needed).
8. **Malformed-PNG fallback** — banner + rectangular fallback per FR-10.
9. **HoloscapeClassic PNG** — generate a procedural PNG via the existing Pillow script, replacing the manifest's `windowShape` field with `chromeImage`. Keep the Winamp-2.x aesthetic.
10. **Docs** — `docs/png-chrome-format.md` — skin-author reference. Template PNG + Pillow-script scaffold.
11. **Integration test** — extend `BackwardCompatIntegrationTests` to cover the PNG-chrome path.
12. **Debug alpha overlay** — FR-9. Optional for MVP; can ship in a follow-up PR.

## 13) Post-MVP

- **`.wsz` import.** Parse Winamp's ZIP bundle + `region.txt` + sprite bitmaps + `viscolor.txt` and synthesize a `.wamp`. Proof-of-concept: a subset of classic `.wsz` skins renders correctly in Holoscape.
- **Multiple PNG layers.** Separate "chrome base" + "chrome hover" + "chrome pressed" PNGs for whole-window state transitions (rare — individual buttons already use sprite sheets).
- **Animated chrome.** Short MP4 or GIF background for skins that want motion.
- **Skin gallery.** A built-in browser for `.wamp` bundles published by the community. Requires a distribution model (github.com/holoscape/skins?).
- **Per-monitor DPI variants.** Skin authors ship `chrome@1x.png` + `chrome@2x.png` + `chrome@3x.png` for pixel-perfect chrome on any display.
- **`ChromeImageDescriptor.regions`.** Declare opaque sub-regions as "drag handles" or "resize handles" directly on the chrome image, not via separate polygon lists.

## 14) Constraints and Governance

- **Follow project governance and review protocol.** Every PR against this work goes through `/pr` with the `code-reviewer` agent and passes Gate 0 scan. Same as all other Holoscape work.
- **Use validation commands before completion.** `swift test` must be green; `./bundle.sh` must succeed; live visual verification is required on the laptop before merging any PR that changes window rendering.
- **Update `PROGRESS.md` and the Amplify spec.** Each PR flips the relevant `tasks.md` entries and updates `PROGRESS.md` if it changes the session's starting point.
- **Preserve Amplify v1 pipeline during the transition.** v3 skins (polygon `windowShape`) continue to load under the legacy path until every v3 reference skin has a v4 PNG-chrome equivalent. No hard cutover; side-by-side coexistence.
- **Backward-compat tests are load-bearing.** `BackwardCompatIntegrationTests` must cover: v2 directory, v2 `.wamp`, v3 directory, v3 `.wamp`, v4 PNG-chrome directory, v4 PNG-chrome `.wamp`. Any PR that breaks one of those blocks.

## 15) Risks

- **AppKit may not honor per-pixel PNG alpha on an `NSImageView`-backed borderless window.** Low risk — the pattern is well-documented and used by e.g. OmniGraffle and Sketch for their chrome. Mitigation: early prototype (first PR) installs a known-good alpha PNG and verifies transparency before writing any of the anchoring machinery.
- **Hit-test perf on large PNGs.** A 4096×4096 PNG alpha sample per mouse event is trivial for a single point, but rapid drag events × sample could add up. Mitigation: cache the alpha-channel bytes in a flat `[UInt8]` buffer at load time; O(1) sample.
- **Retina / scale factor drift.** A 1000×700 PNG on a Retina display has 2000×1400 physical pixels. The OS handles this via `contentsScale` on the layer, but hit-test coordinates must round correctly. Mitigation: test path covers 1×, 2×, and 3× backing scale factors explicitly.
- **Skin author confusion with "PNG is the background but subviews live on top."** Moderate. Mitigation: docs + template + debug overlay.
- **Behavior differences across macOS versions.** Low. The transparency recipe is stable from 10.14 onward.
- **Author tooling lock-in to the Pillow script.** Authors who don't want to write Python should be able to open the PNG in any image editor. The Pillow script is a convenience for the bundled reference skins only.
- **We rebuild some of Amplify v1 in vain.** We re-use most of it; the only meaningful loss is the polygon-mask code and the `HitRegionSampler` implementation. Both are contained and documented as sunset in the transparency-findings doc.

## 16) Dependencies

- Existing Amplify v1 infrastructure: `SkinEngine`, `WampBundleLoader`, `SkinContext`, sprite engine, font pipeline, bundle cache, skin picker, hot reload, malformed-skin banner.
- Existing `ShapedBorderlessWindow` subclass (canBecomeKey / canBecomeMain overrides).
- `NSImage` / `CGImage` for PNG decode (Foundation).
- `CGContext` for alpha-channel sampling (Foundation).
- No new third-party Swift packages required for MVP.

## 17) Open Items

- **Anchor coordinates: top-left or bottom-left origin?** PNG-native is top-left (image editors use it). AppKit is bottom-left. Propose top-left in the manifest; convert internally. Doc it clearly.
- **Multiple chrome states (normal / focus-lost)?** If the app loses focus, does the chrome get a desaturated variant? Nice but not MVP.
- **Does the terminal view's opaque `layer.backgroundColor` cause issues again?** Under the PNG-chrome model, the terminal is positioned inside the PNG's opaque region, so its opaque bg is fine. The CA-masking problem doesn't apply because there's no mask.
- **Should AmplifyDemo migrate to PNG chrome?** Probably yes for consistency. AmplifyDemo's aggressive octagon would translate cleanly.
- **What happens to `dragRegions` in the manifest?** Dropped in MVP — `isMovableByWindowBackground` covers the whole PNG-opaque region. Post-MVP can re-introduce if specific drag-only zones are desired (e.g. a Winamp-style top title bar vs. clickable content below).
- **Does the shader compositor still work inside the PNG's opaque region?** Should. The shader's `CAMetalLayer` lives inside the terminal's subview; the PNG is behind it. Verify in an early PR.
- **Sunsetting `windowShape: polygons`.** Keep it loadable (warning) for one release cycle, then remove.
- **Test harness for "does alpha actually show the desktop"?** Can't easily assert in XCTest — requires a compositor. Plan: one UI test on the Mac Mini that screenshots the app over a known bright-colored backdrop and samples a cut-corner pixel. Deferred.
