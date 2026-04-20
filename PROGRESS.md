# Holoscape — Session Progress (2026-04-20 morning)

## START HERE

**Status**: PRD + spec for the PNG-chrome 20-PR rollout are on `main`. **PR #1 merged. Risk #1 cleared — but with a significant architectural finding that amended the spec.** Open PR (`docs/chrome-risk1-finding`) captures the finding and amends Requirement 3.1, Design Component 9, and Tasks 11.1 + 13.1.

**Next session: review + merge the open PR, then start PR #2 (data model for Chrome v4).**

Read in this order:
1. `docs/png-chrome-prd.md` — the PRD. Source of truth for what ships.
2. `claude-specs/chrome/{requirements,design,tasks}.md` — the generated Kiro spec. 16 requirements / 111 ACs / 12 correctness properties / 20 task groups mapped 1-to-1 with the PRD's 20 PRs.
3. `docs/research/chrome-risk1-transparency-findings.md` — **new this session.** Why PR #5's chrome-mode branch must CONSTRUCT a new window, not reconfigure the existing one.

---

## What shipped this session

### Spec + PRD (merged)

- **PR #146** (merged) — full PRD rewrite making animated chrome a first-class MVP primitive. Generated Kiro spec (`claude-specs/chrome/`) + Kiro IDE parallel spec (`.kiro/specs/png-chrome/`) for side-by-side comparison. Web Claude reviewed; three blocking issues fixed (data-source stub, InteriorView hierarchy diagram, HoloscapeClassic-live deletion gate) + four Kiro artifacts grafted into the Claude spec (worked JSON example, cache layout, shader preset table, property-test iteration conventions) + one self-caught gap (dataSource validator AC).

### PR #1: Transparency prototype (merged + investigated)

- **PR #147** (merged) — the transparency prototype. Shipped:
  - `tools/chrome_prototype/generate_known_good_alpha.py` — Pillow fixture generator. 1000×700 RGBA, 64-px cut corners, pixel-asserted alpha 0 at corners and 255 at center.
  - `Sources/Holoscape/Resources/Prototype/known_good_alpha.png` — generated fixture.
  - `Sources/Holoscape/Views/ChromeHostView.swift` — minimal `NSView` stub with `layer.contents = image` and `hitTest -> nil`. Evolves into the full compositing host in PR #3.
  - `Sources/Holoscape/Controllers/MainWindowController.swift` — `applyPngChromePrototype()` method, gated by `HOLOSCAPE_PNG_CHROME_PROTOTYPE=1`.
  - `Package.swift` — `.copy("Resources/Prototype")` to bundle the fixture.
  - `docs/chrome-prototype-verification.md` — laptop visual check procedure.

### Risk #1 investigation

Erik ran the prototype on the laptop. **First screenshot looked like it passed**, then on closer inspection: the cut corners were opaque dark charcoal, NOT desktop. That was the failure mode of Amplify v1 coming back in a different guise.

Diagnostic round added:
- `frameView.layer.backgroundColor = nil` fix (from Amplify investigation) — didn't help.
- Runtime dump of all Cocoa transparency recipe properties — all correct at render time.
- CGImage pixel dump at (0,0), (32,32), (500,350) — alpha preserved through decode.
- **Isolation test**: second fresh borderless `NSWindow` built from scratch alongside the main one, same fixture, same code path. Floating window level so Erik could see it distinctly.

**Finding**: the isolation window showed transparent cut corners. The main window did not. Every runtime property on both was configured identically. **AppKit locks in opaque backing at window construction time; no property flip after the fact can undo that.** The Cocoa Transparency Recipe only works on a borderless-from-birth window.

Full write-up: `docs/research/chrome-risk1-transparency-findings.md`.

### Open PR (`docs/chrome-risk1-finding`)

Amends the spec to encode the finding:

- **Requirement 3.1** — now says the window must be CONSTRUCTED borderless + transparent, not reconfigured. Added 3.1a for the inverse case (v4 → pre-v4 swap needs a fresh titled window).
- **Design Component 9** — new methods `reconstructAsBorderlessTransparent(size:)` and `reconstructAsTitled(size:)`. These handle delegate + child window + first responder migration.
- **Task 11.1 (PR #5)** — window reconstruction is now the first step, not last. Task 13.1 updated to note the window is already constructed correctly from PR #5.
- **Research note** — `docs/research/chrome-risk1-transparency-findings.md`.

---

## What's on `main` right now

### Code
- All Amplify v1 infrastructure (sprite sheets, fonts, borders, `.wamp`, hot reload, banner, etc.) — stays, carries forward into Chrome MVP as dependencies.
- Shaped-window lifecycle code (reconstruction, mask install, drag overlay, polygon scaling) — stays on main, will be deleted in Chrome PR #20 (Task 39).
- Shaped skins (HoloscapeSynthwave, HoloscapeClassic, AmplifyDemo) — still ship, still render with their v3 windowShape (opaque dark corners today; fixed by migrating to v4 chrome in Phase 3).
- **PR #1 prototype code**: `ChromeHostView.swift`, `applyPngChromePrototype()`, `Resources/Prototype/known_good_alpha.png`, `tools/chrome_prototype/generate_known_good_alpha.py`. Gated by env flag; removal scheduled in tasks.md final PR.

### Specs
- `claude-specs/archive/amplify/` — Amplify v1 spec, marked superseded.
- `claude-specs/chrome/` — the current spec (on `main`). Further amended by the open PR.
- `claude-specs/chrome-skinning/` — pre-Amplify chrome-skinning spec (kept for v3 reference).
- `.kiro/specs/png-chrome/` — Kiro IDE's parallel generation for comparison.
- `.kiro/specs/amplify-skinning/` — Kiro's parallel Amplify spec.

### Docs
- `docs/amplify-prd.md` — Amplify v1 PRD (superseded for shape + drag; still accurate for the v3 capabilities).
- `docs/amplify-format.md` — `.wamp` skin author reference.
- `docs/png-chrome-prd.md` — **the active PRD.**
- `docs/chrome-prototype-verification.md` — PR #1 laptop visual check procedure.
- `docs/research/shaped-window-transparency-findings.md` — Amplify v1 investigation.
- `docs/research/shaped-window-architecture-prd.md` — web Claude's architecture proposal.
- `docs/research/chrome-risk1-transparency-findings.md` — **new**, PR #1 retrofit-vs-reconstruct finding.

## Tests

729 green on laptop (PR #1 didn't change the count; no new tests in the prototype). No regressions.

## Open cards

None on the project board — the 20-PR plan IS the work. Next card to create (or not — the spec tasks.md is sufficient): **PR #2 — Data model for Chrome v4** (`ChromeDescriptor`, `SkinRect`, `ChromeAnimationLayer` + per-kind params, `SkinDefinition` v4 field, Codable tests). Mechanical; every field is specified in `claude-specs/chrome/design.md` Data Models section.

## Branches outstanding

- `docs/chrome-risk1-finding` — the open PR. Research note + spec amendments + this PROGRESS.md update.

## Cleanup deferred

Per `claude-specs/chrome/tasks.md` Task 39 (PR #20) — the existing `ShapedWindowController.buildMaskLayer`, `WindowDragOverlay`, polygon scaling helpers, `writeShapeDiagnostic`, pre-v4 `HoloscapeClassic` skin directory, and PR #1 prototype code all get deleted together, AFTER HoloscapeClassic-live + HoloscapeSynthwave + AmplifyDemo all migrate to v4 chrome with animations verified live.

## Note for future me

The Risk #1 investigation is a template for how the rest of the MVP should validate architectural assumptions: **build the isolation test before trusting the integration.** If PR #5's window reconstruction hits surprises, do the same thing — construct a minimal fresh window in isolation, confirm the recipe works, then integrate. Don't grind on property flips hoping the bug goes away.

Two things saved time this session:
1. Keeping the prototype branch isolated (env flag gated) meant we could investigate without risking the main app.
2. Asking Erik to run one binary invocation with stderr captured produced the diagnostic that cracked the case.

Two things cost time:
1. Misreading the first screenshot as a pass. The surrounding desktop content at the top of the screen was not-through-the-window; the "transparency" I thought I saw was a framing illusion. **Always look at what's outside the window bounds vs inside the cut corners separately.** When in doubt, ask for a screenshot over a solid white wallpaper.
2. Assuming "same recipe = same result" between a newly-constructed window and a reconfigured existing window. AppKit's window backing is not purely property-driven; some state is fixed at construction. This was not in any public documentation I could find.
