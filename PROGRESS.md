# Holoscape — Session Progress (2026-04-19 evening → 2026-04-20 early morning)

## START HERE

Amplify v1 is complete — the v3 skin manifest and everything it carries (sprite sheets, font consumption, border/corner/shadow on individual chrome surfaces, `.wamp` bundle format, malformed-skin banner, fixed-size keyable borderless windows, hit sampling, drag regions) all ship on `main`. **One thing did not ship: actual window-level transparency at cut corners.** After ~6 hours of investigation, the `CALayer.mask` approach was found to be fundamentally incompatible with Holoscape's view tree. **Pivoting to a PNG-alpha chrome architecture** — the approach Winamp, Spotify, OmniGraffle, Sketch all use.

**Read `docs/png-chrome-prd.md` first.** It's the merged PRD (my draft + web Claude's independent proposal, synthesized). That document is the source of truth for what ships next.

Next session is either:
1. Run `/spec` against `docs/png-chrome-prd.md` to generate `claude-specs/chrome/{requirements,design,tasks}.md` in Kiro format. Then `/strategy` for PR-level decomposition.
2. OR skip the spec step and start on PR #1 of the MVP directly (the end-to-end transparency prototype).

---

## What shipped today — Amplify v1 complete

**Ten PRs merged to `main`** (#134 → #142 plus PR #143 still open for the PRD). **Six cards closed**. **Multiple Amplify spec task groups flipped**. **730 tests green on laptop** (last full run before the transparency pivot; no test changes since).

### Overnight → afternoon: shape lifecycle + polish

| PR    | Title                                                              | Closes |
|-------|--------------------------------------------------------------------|--------|
| #134  | shaped-window reconstruction double-release (`isReleasedWhenClosed`) | #6036  |
| #135  | content-view repaint after reconstruction (`forceRedisplay`)        | #6038  |
| #136  | polygon scaling + fixed-size + keyable borderless + drag overlay    | #6037  |
| #137  | malformed-skin banner (`SkinWarningBanner`)                         | Task 21.2 |
| #138  | logging audit + parent-spec link                                    | Task 21.3, 21.5 |
| #139  | wire shared `AnimationEngine` into app object graph                 | #6027  |
| #140  | PROGRESS.md refresh (mid-day)                                       | —      |
| #141  | HoloscapeClassic — second v3 skin, programmatic sprites             | Tasks 19.2, 19.4 |
| #142  | HoloscapeClassic sprite generator — anchor OUT_DIR to repo root    | review follow-up |

**Card #6039** was closed as wontfix (not a real bug — the magenta "wedge" at bottom-left is the selected channel sidebar entry rendering with the skin's deliberately-loud `sidebar.row.selected` fill, clipped by the cut-corner mask; correct engine behavior).

### Architecture as it now stands on `main`

- `NSWindow` ← `.borderless` when shaped (via `ShapedBorderlessWindow` subclass with `canBecomeKey`/`canBecomeMain` overrides), `.titled` otherwise.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` for shaped.
- `ShapedContentView` — content view with hit-region sampler override for click-through.
- `CAShapeLayer` mask installed on `contentView.layer`. **This is the piece that doesn't actually produce transparency at cut corners** (see investigation below).
- `HitRegionSampler` for polygon point-in-polygon (fast, works).
- `DragRegionTracker` for skin-declared drag regions with `NSTrackingArea` installation.
- `WindowDragOverlay` — 20pt invisible strip at the top for whole-window drag (Req 4.6 fallback).
- Fixed-size window: `contentMinSize == contentMaxSize == nominalSize`, `.resizable` stripped.
- Polygon scaling + `windowDidResizeForShape` observer for resize adaptation (unused in fixed-size mode but kept for future flexibility).
- Shipped skins: `HoloscapeSynthwave`, `HoloscapeClassic`, `AmplifyDemo` (all v3, all have `windowShape` polygons).

All of the above **renders a shaped window with working click-through, working drag, working keyboard input**. What it doesn't do is **make the cut-corner pixels transparent to the desktop**.

---

## The investigation — what broke, why we pivoted

### What we expected

Per Apple's Core Animation guide: `CALayer.mask` on an ancestor clips every descendant's composited output. Setting `window.isOpaque = false` + `window.backgroundColor = .clear` lets the window compositor honor per-pixel transparency. Together these should produce a shaped, transparent window.

### What actually happens

Every documented property IS correctly set at runtime — confirmed via a runtime diagnostic (`writeShapeDiagnostic`) that dumps the full CALayer tree + NSView subview walk + `contentView.superview` (NSNextStepFrame) probe. Log shows:

- `window.isOpaque = false` ✓
- `window.backgroundColor = Generic Gray 0 0` (i.e. `.clear`) ✓
- `window.hasShadow = false` ✓
- `contentView.layer.mask` installed with correct frame `(0,0,1000,700)` ✓
- `contentView.layer.backgroundColor = nil` ✓
- `contentView.layer.isOpaque = false` ✓
- `frameView.layer.backgroundColor = nil` (AppKit had been auto-setting it to `window.backgroundColor` at `wantsLayer`-promotion time; fixed with a targeted assignment) ✓
- Every chrome-band subview has `bg = nil` ✓

Yet the cut-corner regions render opaque dark.

### The smoking gun — shrink-polygon experiment

Temporarily shrank HoloscapeClassic's polygon to a 200×200 square in the center of the 1000×700 window. Result:

- **Terminal content (bash prompt, sprite art) only rendered inside the 200×200 region.** The mask IS clipping drawn content.
- **Outside the 200×200 region, the sidebar's opaque `(0.05, 0.05, 0.1, 1)` and terminal's opaque `(0, 0, 0, 1)` layer backgrounds rendered as if the mask wasn't there.** Confirmed via a 50%-red tint on `contentView.layer.backgroundColor` — the red only showed in sliver gaps between subview layer frames.

Root finding: **`CALayer.mask` appears to clip drawn content (`contents`, text, sprites) but NOT descendant layers' `backgroundColor`.** This contradicts Apple's CA documentation. No concrete source (forum post, WWDC session, SO answer, open-source reference) was found that explains the bypass. The behavior is observable; the reason isn't documented.

### Why we can't work around it

Every new subview we add could have an opaque `backgroundColor` set by a skin or a third-party view (SwiftTerm sets `layer.backgroundColor` on its terminal view; it ships that way). "Audit every descendant's layer bg before every shape change" is not an architecture — it's a recurring tax on every future feature.

Full findings preserved at `docs/research/shaped-window-transparency-findings.md`.

---

## The pivot — PNG-alpha chrome architecture

**"One alpha-aware renderer owns every visible pixel."** This is what Winamp (PNG), Spotify (WebView), Audion, SoundJam, OmniGraffle, Sketch all do. Every shipping shaped-window macOS app uses the same pattern.

### The merged PRD — `docs/png-chrome-prd.md`

I drafted a PRD in Erik's 17-section template. Independently, web Claude drafted a technical memo with the `ChromeHostView` + `InteriorView` architectural primitive. Erik asked us to synthesize. The merged PRD is on branch `docs/png-chrome-prd` (PR #143 open).

### Core architecture (from the merged PRD)

```
NSWindow (.borderless, isOpaque=false, bg=.clear, hasShadow=false)
  └── ShapedContentView  (existing class, now a thin host)
        └── ChromeHostView  ← single layer-backed NSView, fills content bounds
              │   layer.contents = RGBA image; alpha IS the window shape
              │   no interactive subviews inside it
              └── InteriorView  ← pinned to skin.chrome.interiorRect
                    │   OWNS every piece of app content
                    │   OPTIONAL: layer.mask for concave interiors only
                    ├── TabBarView
                    ├── NSSplitView (sidebar + rightPane + terminal)
                    └── InputBoxView
```

Key invariants:
- `ChromeHostView.layer.contents` is the ONLY layer whose alpha contributes to window shape.
- `InteriorView` is geometrically inside the chrome's opaque region — app content is inside the polygon **by construction, not by masking**.
- No mask on the window content view.
- Adding a new subview can't break the shape because all content goes into `InteriorView`.

### Authoring modes

- **`chrome.mode: "baked"`** — skin author ships `chrome@2x.png` (plus optional `chrome-opaque@2x.png` for Reduce Transparency).
- **`chrome.mode: "composed"`** — skin declares v3 surfaces as today; engine composites a chrome image at load time from the surfaces + sprites + ninepatches, caches by SHA, installs. HoloscapeSynthwave + AmplifyDemo migrate with zero author work.

### What MVP preserves from Amplify v1

- `HitRegionSampler` (polygon hit testing) — carries forward verbatim
- `DragRegionTracker` (drag region polygons + tracking areas) — carries forward verbatim
- `ShapedBorderlessWindow` subclass (canBecomeKey/Main overrides) — kept
- `isReleasedWhenClosed = false` crash fix — kept
- `.wamp` bundle format, sprite sheets, font consumption, border/corner/shadow on individual surfaces, skin picker + hot reload, malformed-skin banner, fixed-size windows — all carry forward
- `windowShape.polygons` descriptor — stays (drives hit testing + drag regions + polygon-vs-chrome-PNG cross-check validator)

### What MVP deletes (step 15, after both in-tree skins migrate)

- `ShapedWindowController.buildMaskLayer` for content-view masking (moves to optional `InteriorView.layer.mask` for concave interiors only)
- `WindowDragOverlay` — replaced by `isMovableByWindowBackground` + chrome alpha
- Polygon scaling + `windowDidResizeForShape` observer — PNG chrome is fixed-size by construction
- `writeShapeDiagnostic` infrastructure from the investigation branch (never merged to main)

### Estimate

~7 focused days, ~15 PRs in rough order (per the PRD § MVP Scope).

---

## Cleanup completed this session

- **Old Amplify spec archived.** Moved `claude-specs/amplify/` → `claude-specs/archive/amplify/`. Added `claude-specs/archive/README.md` explaining supersession.
- **New chrome spec stub.** Created `claude-specs/chrome/README.md` pointing at the PRD. Actual `requirements.md`/`design.md`/`tasks.md` generation is a next-session task via `/spec`.
- **Kiro spec (`.kiro/specs/amplify-skinning/`)** left alone per Erik — we always drive work off the Claude spec, Kiro is secondary reference.
- **Investigation findings and web Claude's PRD** both preserved at `docs/research/` so future agents can see the reasoning behind the pivot without having to reconstruct it.

## Cleanup deferred — pick up next session

The following are currently **still on `main`** but will be deleted/refactored during the chrome MVP. Not touching now because:
- They still make AmplifyDemo + HoloscapeClassic partially work (shape visible, just not transparent at cut corners).
- Touching them without the replacement ready would break those skins with no fallback.

Items:
1. **`ShapedWindowController.buildMaskLayer`** — delete after chrome MVP step 5 (MainWindowController chrome-mode branch) lands.
2. **`WindowDragOverlay`** (`Sources/Holoscape/Views/ShapedContentView.swift`, lines for the overlay class) — delete after MVP step 7.
3. **Polygon scaling helpers + `windowDidResizeForShape`** in MainWindowController — delete after MVP step 15.
4. **AmplifyDemo + HoloscapeClassic `windowShape` fields** — migrate to `chrome.interiorRect` in MVP steps 10 + 11.
5. **Investigation branch `fix/shaped-window-transparency`** — delete after PR #143 merges. All findings preserved at `docs/research/` already.

## Branches outstanding

- **`main`** — clean, all Amplify v1 work merged.
- **`docs/png-chrome-prd`** — PR #143 open, contains the merged PRD + this PROGRESS.md update + spec archival + chrome spec stub + investigation docs.
- **`fix/shaped-window-transparency`** — investigation-only. Findings doc copied to `docs/research/` in PR #143, so this branch can be deleted once #143 merges.
- **`claude/fix-reconstructwindow-crash-KRseC`** — web Claude's branch containing their independent PRD (`docs/research/shaped-window-architecture-prd.md`). Content copied into PR #143 for cross-reference, so this remote branch can be deleted once #143 merges.

## What's on `main` right now (the starting point)

### Code
- All Amplify v1 infrastructure (sprite sheets, fonts, borders, `.wamp`, hot reload, banner, etc.) — stays.
- Shaped-window lifecycle code (reconstruction, mask install, drag overlay, polygon scaling) — stays for now, will be partially replaced in chrome MVP.
- Shaped skins (HoloscapeSynthwave, HoloscapeClassic, AmplifyDemo) — still ship, still partially render as shaped (click-through works, visual transparency doesn't).

### Specs
- `claude-specs/archive/amplify/` — Amplify v1 spec, marked superseded.
- `claude-specs/chrome/README.md` — stub for the new work.
- `claude-specs/chrome-skinning/` — pre-Amplify chrome-skinning spec (kept, still accurate for the v3 surface pipeline).
- `.kiro/specs/amplify-skinning/` — Kiro's parallel spec (reference only).

### Docs
- `docs/amplify-prd.md` — Amplify v1 PRD (superseded for shape + drag; still accurate for the v3 capabilities).
- `docs/amplify-format.md` — `.wamp` skin author reference (still accurate).
- `docs/png-chrome-prd.md` — **the new PRD, source of truth for what ships next.**
- `docs/research/shaped-window-transparency-findings.md` — why we pivoted.
- `docs/research/shaped-window-architecture-prd.md` — web Claude's proposal.

## Tests

730 green on laptop, last full run after PR #142. No test changes since — the investigation branch was diagnostic-only. Full suite still expected to pass on `main`.

## Open cards

Holoscape project board is effectively empty after today. Everything concrete maps to the PRD's MVP. The next card to create is "Chrome MVP — PR 1: end-to-end transparency prototype with a known-good alpha PNG," to validate the architecture's load-bearing assumption (AppKit honors per-pixel PNG alpha on a borderless window) before writing any of the machinery above it. File that first thing next session.
