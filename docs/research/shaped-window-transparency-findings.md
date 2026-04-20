# Shaped-Window Transparency — Research Findings

**Session**: 2026-04-19, late evening
**Context**: Erik told me to stop guessing and do real research before writing more code.
**Status**: Research complete. Root cause identified. Action plan pending approval before any code changes.

---

## Failure mode (from Erik's report)

Borderless `NSWindow` with a `CAShapeLayer` mask on `contentView.layer`:
- **Click-through works** — clicks in the cut-corner regions pass through to whatever is behind the app.
- **Visual transparency fails** — the cut-corner regions paint as opaque dark grey. The desktop is NOT visible through them.

This is true on both **AmplifyDemo** (40 px cut corners) and **HoloscapeClassic** (16 px cut corners).

What I already tried, unsuccessfully: `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, reordering `applyWindowShape` before `applyWindowSurfaces`, clearing `backgroundColor` when `currentWindowShape != nil`.

---

## Root cause (cited)

Two independent defects, both needed to fix:

### 1. AppKit assigns a default opaque layer backgroundColor when `wantsLayer = true`

`MainWindowController.swift:1116` does `contentView.wantsLayer = true` immediately before installing the mask. After that call, AppKit may assign a **default opaque `backgroundColor`** to the layer. A `CAShapeLayer` mask DOES clip a child layer's backgroundColor (confirmed against `CALayer.mask` documentation), BUT it does not clip the masked layer's *own* backgroundColor — that's the `contentView.layer` itself, which sits **inside** the mask region everywhere including the cut corners. The mask clips what's BEHIND the mask; the masked layer's own backgroundColor is what draws there.

We never explicitly clear it:

```bash
$ grep "contentView.layer.*backgroundColor" Sources/Holoscape/Controllers/MainWindowController.swift
# (no matches — we never set it to nil/.clear)
```

**Fix**: `contentView.layer?.backgroundColor = nil` right after `wantsLayer = true`.

**Source**: Apple CA Guide, `CALayer.mask` documentation, Cocoa With Love (canonical borderless-window reference).

### 2. SwiftTerm sets the terminal view's layer backgroundColor to opaque

`MacTerminalView.swift:396` in SwiftTerm (our dependency) does:
```swift
layer?.backgroundColor = nativeBackgroundColor.cgColor
```

This sets the *terminal view's* own layer backgroundColor to an opaque color (black by default). The terminal view is a subview of our content view; its layer is a sublayer of `contentView.layer`.

A parent's `layer.mask` DOES clip child sublayers, including their backgroundColors (this is well-documented CA behavior). So in theory this is fine.

BUT — the terminal view's frame covers most of the window's interior, including pixels at the corners that the polygon cuts out. When the mask clips the terminal view, the clipped pixels show whatever is *further behind* — which in the current setup is the content view's own opaque default backgroundColor (Defect 1).

So Defect 2 alone wouldn't cause the failure, but Defect 2 means that even after fixing Defect 1, we need to confirm the mask is actually clipping the terminal view correctly. Verification-only item.

### 3. `CAMetalLayer` bypasses parent-layer masks (NOT the current bug, but a future one)

The research flagged this as the primary candidate, but I verified it's NOT the current bug:

- `MetalCompositor` (our custom shader overlay) only instantiates when a compiled shader is loaded. Default launch has no shader → no `CAMetalLayer` in the tree.
- `SwiftTerm.MacTerminalView` has an optional `MTKView` backing (which uses `CAMetalLayer`), but it's opt-in via `updateMetalRenderer(enabled: true)`. Holoscape never calls that — the terminal uses SwiftTerm's CoreText path, not Metal.

So there's no live `CAMetalLayer` in the rendering tree right now. **But when a user loads a custom shader (feature the app supports), the `CAMetalLayer` from `MetalCompositor` WILL bypass the mask and the cut corners will break again.** Need to fix for completeness, but not urgent.

**Source**: Apple Developer Forums thread/724223 (Apple engineer confirming CAMetalLayer uses direct IOSurface compositor path, which bypasses CA masking). This is the most authoritative public source, though Apple doesn't document it formally.

---

## Answers to every question I wrote down

Addressing each item from my pre-research to-do list:

### Q1: Is `isOpaque = false` actually taking effect at render time?

**Yes, but it's necessary-not-sufficient.** `isOpaque = false` on the window tells AppKit the window has a per-pixel alpha channel. It doesn't control what any specific layer paints; it just allows a transparent compositing path.

Confirmed in `ShapedWindowController.swift:329`:
```swift
newWindow.isOpaque = isOpaque  // `false` when targetShape != nil
```

**Action**: none — already correct.

### Q2: What's the final value of `window.backgroundColor` after `applySkin` completes?

Before my last change: clobbered by `applyWindowSurfaces` to the skin's top-gradient stop (e.g. `#6a6a72` for Classic).

After my last change: `.clear` when `currentWindowShape != nil`, which we verified is correct for the new code path.

**Action**: keep the last change (clear when shaped). That part was right.

### Q3: Is `contentView.layer.mask` still attached at render time?

We install it here (`MainWindowController.swift:1135`):
```swift
contentView.layer?.mask = maskLayer
```

`forceRedisplay(_:)` only calls `setNeedsDisplay` on children; it doesn't touch the mask. The resize observer re-applies it. No code path clears `layer.mask`.

**Action**: none. Mask stays attached. (Still worth a one-line diagnostic log to confirm at runtime, but I'd be surprised if this is wrong.)

### Q4: Does `CAMetalLayer` respect parent-layer masks?

**No.** Apple engineer confirms CAMetalLayer bypasses CA masking via the IOSurface compositor path. `layer.mask` on an ancestor does NOT clip a `CAMetalLayer` sublayer.

**Action (deferred)**: when custom shader is enabled, apply the mask directly to `MetalCompositor.metalLayer` instead of (or in addition to) the contentView mask. Also set `metalLayer.isOpaque = false`, `metalLayer.framebufferOnly = false`, and clear-color alpha to 0. NOT needed for the current default-launch failure, but needed when shaders are used.

### Q5: Default value of `CAMetalLayer.isOpaque`?

**`true`.** Confirmed from Apple's own `CAMetalLayer.h` header file. Also the default `framebufferOnly = true` prevents alpha preservation. Both must be flipped for transparent Metal rendering.

**Action (deferred)**: same as Q4 above.

### Q6: Are there AppKit quirks where `contentView.layer.mask` fails to clip sublayers?

**Yes — for `CAMetalLayer` / `MTKView` backed subviews.** Because they use the IOSurface direct compositor. Not applicable here in default launch (no Metal views active). Applicable when shaders are enabled.

For regular CALayer sublayers (including SwiftTerm's terminal view's plain layer), the mask DOES clip them correctly.

**Action**: covered by Q4/Q5 deferred work.

### Q7: Do intermediate view layers need `masksToBounds`?

**No.** `masksToBounds` clips children to the current layer's bounds; it doesn't affect parent masking. The content view's `layer.mask` is sufficient to clip all regular-CALayer descendants.

**Action**: none.

### Q8: Does `BackingStoreType.buffered` vs `.nonretained` affect transparency?

**No practical effect.** `.buffered` supports per-pixel alpha (which we need) and is what we're using. `.nonretained` is effectively deprecated for content windows.

**Action**: none.

### Q9: Does `window.level` or other window properties affect transparency?

**No**, not for per-pixel transparency. `window.level` affects z-ordering only. `window.alphaValue` is a whole-window fade (not per-pixel). Neither is a factor.

**Action**: none.

### Q10: Does `contentView.layer.backgroundColor` need explicit clearing after `wantsLayer = true`?

**YES — this is the main bug for the current default-launch failure.** AppKit can assign a default opaque backgroundColor to the content view's layer when `wantsLayer` is set. That opaque color paints behind everything and shows through the mask's cut corners.

**Action (primary fix)**: explicitly set `contentView.layer?.backgroundColor = nil` after `wantsLayer = true`.

---

## Action plan (pending approval)

### Fix A — primary, needed right now

In `MainWindowController.applyWindowShape`, immediately after `contentView.wantsLayer = true`:

```swift
contentView.wantsLayer = true
contentView.layer?.backgroundColor = nil
contentView.layer?.isOpaque = false
```

Two lines. Surgical. Addresses the default-launch failure Erik is seeing.

### Fix B — deferred, needed when custom shaders are enabled

In `MetalCompositor.init`:

```swift
ml.isOpaque = false
ml.framebufferOnly = false
```

In `MetalCompositor.renderFrame` clear color:

```swift
passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
```

And apply the shape mask directly to `metalLayer` (separately from the contentView mask) when a shape is active. Needs a wiring surface from `MainWindowController` to `MetalCompositor` — more invasive.

**Not needed to unblock Erik's current transparency test** (no shader loaded).

### Fix C — verification (not a fix, just proof)

Before making Fix A, temporarily add:

```swift
NSLog("[shape-diag] isOpaque=\(window.isOpaque) bg=\(window.backgroundColor?.description ?? "nil") mask=\(contentView.layer?.mask != nil) contentLayerBg=\(contentView.layer?.backgroundColor?.description ?? "nil") contentLayerOpaque=\(contentView.layer?.isOpaque ?? true)")
```

Run, read the log. If `contentLayerBg` is non-nil or `contentLayerOpaque` is true, that confirms the hypothesis. If neither is, we learn something new and avoid another guess.

### Scope discipline

- **Fix A** + **Fix C** in one PR. Small, testable, directly answers Erik's "we can't make any part of the window transparent" report.
- **Fix B** in a separate PR, only if Erik wants shader transparency to work.

---

## What I'm NOT proposing

- No more shotgun changes to `hasShadow`, `applyWindowSurfaces` ordering, or anything else that wasn't identified by this research.
- No "let me try another thing" without first verifying via Fix C.
- No changes to Metal code unless Erik explicitly asks for shader transparency.

---

## Sources

Full citation list in the researcher's report (see session transcript). Primary references:

- Apple CA Guide — `CALayer.mask` behavior
- Cocoa With Love (2008, canonical) — borderless window transparency recipe
- Apple Developer Forums thread/724223 — CAMetalLayer IOSurface bypass (engineer Quinn)
- Apple `CAMetalLayer.h` header — `isOpaque` defaults to true
- SwiftTerm `MacTerminalView.swift:396` — terminal view sets its own `layer.backgroundColor`
- Local grep confirmed: `contentView.layer?.backgroundColor` is NEVER explicitly set anywhere in Holoscape after `wantsLayer = true`

---

## Ask

1. Read this document.
2. Approve Fix A + Fix C as a single PR.
3. Defer Fix B until you want shader transparency.

Or redirect — tell me what I got wrong or what else to investigate first.

---

## POSTSCRIPT — results of the implementation (2026-04-19 night)

**Fix A did not resolve the failure.** Runtime diagnostic (`writeShapeDiagnostic` in `MainWindowController.swift`, output at `/tmp/holoscape-shape-diag.log`) confirmed every property is correctly set:

- `window.isOpaque = false`
- `window.backgroundColor = Generic Gray 0 0` (i.e. `.clear`)
- `window.hasShadow = false`
- `contentView.layer.mask = true`, frame `(0,0,1000,700)`
- `contentView.layer.backgroundColor = nil`
- `contentView.layer.isOpaque = false`
- `frameView.layer.backgroundColor = nil` (after targeted fix — AppKit had been auto-setting it to `window.backgroundColor` at wantsLayer-promotion time)
- Every chrome-band subview has `bg = nil`

Yet the cut-corner regions still render opaque dark.

### What the "shrink the polygon to a 200×200 center square" test revealed

Temporarily set HoloscapeClassic's polygon to a small central rectangle. Result:

- **The mask IS clipping visible content.** Terminal text and rendered sprites only appear inside the 200×200 polygon region.
- **The mask is NOT clipping descendant layers' `backgroundColor`.** `sidebarContainer.layer.backgroundColor = (0.05, 0.05, 0.1, 1)` and `HoloscapeTerminalView.layer.backgroundColor = (0, 0, 0, 1)` render as opaque rectangles across their entire frames, ignoring the mask on `contentView.layer`.
- Confirmed via 50% red-alpha tint on `contentView.layer.backgroundColor`: the red only appears in sliver gaps between subview layer frames (window edge, split-pane divider, terminal inset). The mask correctly prevents red from rendering outside the polygon, BUT opaque subview backgrounds paint on top of the red without being clipped.

### Root cause hypothesis (not yet proven by Apple docs)

`CALayer.mask` on an ancestor appears to clip **drawn content** (contents property, visible rendered output) but not `backgroundColor` on descendant layers. Apple's CA guide implies the mask applies to "the layer and its sublayers," but the observed behavior contradicts that for the `backgroundColor` property specifically. Possible explanation: `backgroundColor` is rendered via a fast-path that bypasses the ancestor mask in some compositing orders. Definitive source not yet found.

### Decision (Erik, 2026-04-19)

Abandon the `CALayer.mask` polygon approach. Pivot architecture to **PNG-alpha chrome** (Winamp's original 1998 approach): a single `NSImageView` fills the borderless window with a pre-rendered PNG whose alpha channel IS the window shape. Subviews are positioned inside the PNG's opaque regions. Hit testing samples the PNG's alpha. This sidesteps the CA-masking problem entirely because there is no mask — just alpha-channel transparency in an image.

New PRD: `docs/png-chrome-prd.md` (forthcoming).

### What to preserve from Amplify v1

- Sprite sheets (button state variants) — Task 11
- Border/corner/shadow on skinned chrome surfaces — Task 15
- Font consumption — Task 13
- `.wamp` bundle format + SHA-keyed unzip cache — Task 3
- Feature-flag gating (`HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS`) — Task 5.1
- Skin picker + hot reload — chrome-skinning spec
- Malformed-skin banner — Task 21.2

### What dies

- `CAShapeLayer` polygon mask path
- `ShapedWindowController.buildMaskLayer`
- `HitRegionSampler` (polygon point-in-polygon) — replaced by `AlphaHitSampler` (already stubbed in the design doc)
- `windowShape` descriptor with `kind: polygons`
- Per-polygon drag regions (become alpha-rectangle regions or stay as-is)
- Polygon scaling / nominal-size infrastructure
- `WindowDragOverlay` (PNG-alpha approach makes the whole opaque region draggable via `isMovableByWindowBackground` naturally)
