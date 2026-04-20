# Holoscape — Session Progress (2026-04-20)

## START HERE

**Status**: 19 of 20 chrome PRs merged. Phase 1 (static transparency foundation) + Phase 2 (animated layers) + Phase 3 (reference skins + docs) all shipped. Phase 4 cleanup is partial — pre-v4 `HoloscapeClassic` deleted; removal of the CA-mask / `WindowDragOverlay` fallback deferred pending Mac Mini validation of the chrome-mode branch against a live v4 skin.

**Tests**: 896 green on laptop. No regressions through any of the 19 PRs.

**Next session**:
1. Run `HoloscapeClassic-live` on the Mac Mini. Confirm window reconstructs borderless + transparent, all four animations render, cut corners reveal desktop.
2. If clean → open PR #20 Phase 2 (delete `buildMaskLayer`, `WindowDragOverlay`, polygon scaling helpers, `windowDidResizeForShape` observer). Task 39.1–39.3.
3. If broken on the Mini → the reconstruct path has bugs that unit tests didn't catch. Fix before deleting the fallback.

Read in this order:
1. `docs/png-chrome-prd.md` — the PRD.
2. `docs/chrome-format.md` — the author's reference (new this session).
3. `Sources/Holoscape/Resources/Skins/HoloscapeClassic-live/skin.json` — the first in-tree v4 skin. Exercises all four animation kinds.
4. `docs/research/chrome-risk1-transparency-findings.md` — why the window MUST be constructed borderless-from-birth (Risk #1 investigation from the prior session).

---

## What shipped this session — 19 PRs

### Phase 1 — static transparency foundation (PRs #149–#155)

- **PR #149** (Task 3) — Chrome v4 data model. `ChromeDescriptor`, `SkinRect`, `ChromeAnimationLayer` + `DataSource`/`Params`, `ParticleParams`, `LedArrayParams` + nested `Pattern` enum with single-key-discriminator Codable, `SpriteAnimParams`, `ShaderParams`. `SkinDefinition` gains optional `chrome` field. 26 Codable tests.
- **PR #150** (Task 5) — `ChromeHostView` promoted from prototype to Component 1 interface (baseLayer + animatedLayersContainer as z-ordered sublayers). `InteriorView` (Component 2) with static `computedFrame` for top-left-to-AppKit conversion, `CAShapeLayer` mask for concave interiors, all-degenerate-polygon graceful degradation. 21 tests.
- **PR #151** (Task 7) — `ChromeBakePipeline`. SHA-256 cache at `~/Library/Caches/holoscape-skins/<sha>.png`. Baked mode decodes `chrome.image`; composed mode walks v3 surfaces into a 2x CGContext (windowBackground full-rect + tabBar.container top 32pt + sidebar.container left 220pt). Sprite fills supported; ninepatch deferred. LRU purge. 16 tests.
- **PR #152** (Task 9) — `ChromeManifestValidator`. Non-RGBA / dim-mismatch / interiorRect-outside fatal (Req 12.8). Polygon/alpha bbox delta warning, sub-minimum-size warning. Per-animation: unique ids, rect inside bounds, z > 0, per-kind param validation, asset existence. 20 tests.
- **PR #153** (Task 11) — `MainWindowController` chrome-mode branch. `applyChromeSkin` captures first responder → `reconstructAsBorderlessTransparent` (fresh `ShapedBorderlessWindow` with Cocoa Transparency Recipe applied at construction, delegate + child windows migrated) → install ChromeHostView + InteriorView → reparent app subviews → restore first responder. `reconstructAsTitled` inverse. 8 tests.
- **PR #154** (Task 15) — drag via background. `isMovableByWindowBackground = true` on chrome-mode windows. `WindowDragOverlay` excluded from install path.
- **PR #155** (Task 17) — Reduce Transparency variant. `bakePipeline.bake(reduceTransparency:)` uses `imageOpaque` if declared, else opacifies source (alpha→255, silhouette preserved, reverses premultiplication so edges don't darken). Caches at `<sha>.opaque.png`. 3 tests.

### Phase 2 — animated chrome layers (PRs #156–#159)

- **PR #156** (Task 19) — `SharedAnimationClock` (DispatchSourceTimer @ 60 Hz, weak subscribers pruned on tick, `os_signpost` regions). `AnimatedLayerRenderer` protocol. `ParticleLayerRenderer` (CAEmitterLayer, every ParticleParams field → CAEmitterCell, soft-dot fallback, additive/screen blendMode → compositingFilter). 20 tests.
- **PR #157** (Task 21) — `LEDArrayLayerRenderer` (CALayer per cell, 5 patterns all deterministic against phase seconds). `SpriteAnimLayerRenderer` (contentsRect UV advance, loop/pingPong/once modes). 22 tests.
- **PR #158** (Task 23) — `ShaderPresetLayerRenderer` (CALayer-based approximations of glow/scanlines/noise). Full Metal pipeline deferred to a focused future PR once PR #19's signpost traces justify it. 9 tests.
- **PR #159** (Task 25) — container mask from baseImage alpha (Property 7). Density mode transitions (off uninstalls, minimal pauses, full reinstalls from descriptors). Reduce Motion freeze (pauses clock + renderers, layers stay in tree). `accessibilityElementsHidden = true` on container. 4 tests.

### Phase 3 — reference skins + docs (PRs #160–#162)

- **PR #160** (Task 27) — `HoloscapeClassic-live` reference skin. v4 baked mode with all four animation kinds (porthole-sparks particle, status-leds marquee, lcd-marquee sprite, bottom-glow shader). Programmatic chrome + sprite assets via Pillow (`tools/holoscape_classic_live/generate_assets.py`). 5 integration tests — the first end-to-end dogfood of the v4 system.
- **PR #161** (Task 29 + 31) — `HoloscapeSynthwave` → v4 composed (particle + scanlines shader); `AmplifyDemo` → v4 composed (single glow shader). 6 integration tests.
- **PR #162** (Task 33) — `docs/chrome-format.md` + `docs/chrome-template.png`. Skin author reference covering both authoring modes, every animation kind, validator errors, density/Reduce Motion interaction.

### Phase 4 — integration + cleanup (PRs #163–#165)

- **PR #163** (Task 35) — `ChromeBackwardCompatIntegrationTests` extended with six v4 lanes (composed/baked no-anim dirs, all four kinds, minimal single-shader, renderer-count=descriptor-count, v1 backward-compat regression). 7 tests.
- **PR #164** (Task 37.1) — `ChromeDebugOverlay`. Semitransparent alpha pass, interiorRect outline, polygon outlines, animation-rect outlines + id labels, phase-seconds HUD. Gated by `HOLOSCAPE_PNG_CHROME_DEBUG=1`. 4 tests.
- **PR #165** (Task 39.5 — THIS PR) — pre-v4 `HoloscapeClassic` directory + `.wamp` + `HoloscapeClassicIntegrationTests.swift` deleted. Replaced by `HoloscapeClassic-live` (PR #160).

---

## Cleanup deferred (PR #20 Phase 2)

The following code stays on `main` until the chrome-mode branch is verified live on the Mac Mini:

- `ShapedWindowController.buildMaskLayer` + surrounding CA-mask code (Task 39.1)
- `WindowDragOverlay` class + every reference (Task 39.2)
- `polygon scaling` helpers + `windowDidResizeForShape` observer (Task 39.3)

**Why deferred**: `applyChromeSkin` / `reconstructAsBorderlessTransparent` are fully unit-tested, but the window-level reconstruction path (delegate migration, child-window reparenting, first-responder preservation across an NSWindow swap) cannot be exercised in XCTest — it runs on the live main window. Unit tests prove the code compiles + the helpers do what they say; they don't prove AppKit accepts the swap without edge-case failures. Deleting the CA-mask fallback before that verification would break every skin if a reconstruction bug surfaces.

**Unblocking step**: Erik runs `HoloscapeClassic-live` on the Mac Mini, confirms the window renders borderless + transparent with cut corners revealing desktop AND all four animations play at their declared positions. If that lands clean, a follow-up PR deletes the fallback + the associated tests.

`writeShapeDiagnostic` (Task 39.4) is already dead code — only mentioned in spec/docs, no runtime references. No deletion needed; noted for completeness.

---

## What's on `main` right now

### Code (20 v4 files, ~3000 LOC)

- Models: `ChromeDescriptor` + friends in `AmplifyDescriptors.swift`, `chrome` field on `SkinDefinition`.
- Services: `ChromeBakePipeline`, `ChromeManifestValidator`, `SharedAnimationClock`, `AnimatedLayerRenderer` protocol, `ParticleLayerRenderer`, `LEDArrayLayerRenderer`, `SpriteAnimLayerRenderer`, `ShaderPresetLayerRenderer`.
- Views: `ChromeHostView` (Component 1, animated layers wired), `InteriorView` (Component 2), `ChromeDebugOverlay`.
- Controllers: `MainWindowController+ChromeMode.swift` — `applyChromeSkin` + `reconstructAsBorderlessTransparent` + `reconstructAsTitled` + install/reparent/teardown helpers.
- Skins: `HoloscapeClassic-live/` (new baked reference), `HoloscapeSynthwave/` + `AmplifyDemo/` (migrated to v4 composed).
- Pre-v4 skins remaining: none. (HoloscapeClassic/ deleted this PR.)

### Tests (896 green)

- Unit: 20 chrome test files covering every model, service, view, and controller helper.
- Integration: `HoloscapeClassicLiveIntegrationTests`, `V4MigrationIntegrationTests`, `ChromeBakeBackwardCompatIntegrationTests` — end-to-end on the three in-tree v4 skins.
- Backward-compat: existing `BackwardCompatIntegrationTests` still pins v3 `.wamp` ↔ directory parity.

### Docs

- `docs/png-chrome-prd.md` — the PRD.
- `docs/chrome-format.md` — skin author reference (new this session).
- `docs/chrome-template.png` — starter template.
- `docs/chrome-prototype-verification.md` — PR #1 verification procedure.
- `docs/research/chrome-risk1-transparency-findings.md` — Risk #1 investigation.

### Specs

- `claude-specs/chrome/{requirements,design,tasks}.md` — the generated Kiro spec. Amended this session to document the synchronous `bake` signature (design Component 3).

---

## Note for future me

The 19-PR session succeeded because each PR ran the same mechanical pattern:
1. Read the task's design + requirements citations.
2. Write the code to match the spec interface verbatim.
3. Build.
4. Write tests naming the requirements they pin.
5. Run full suite (must stay green).
6. Invoke `code-reviewer` and address findings BEFORE push.
7. Commit via `gha` for bot identity, push with `CLAUDE_PR_REVIEW_PASSED=1`.
8. Open PR via the `pr` skill template, enable auto-merge, watch to merged.
9. Sync main, delete branch, next PR.

Average PR cycle: ~20-30 minutes. The code-reviewer pass caught **8 real issues** across the session (async signature divergence, dead first-responder code, scope-creep `updateInteriorRect`, empty-path mask defect, overclaimed multi-key rejection guard, whitespace image path bypass, missing boundary tests, weak duplicate-id assertion). Every one was a real bug that would have needed fixing later. **The review step is load-bearing.**

Three things to NOT do next session:
1. Do not delete the CA-mask fallback until the Mini confirms chrome-mode reconstruction works live.
2. Do not ship art; programmatic placeholder assets are fine for integration tests, but visual design needs Erik.
3. Do not invent spec deviations silently; if a spec is wrong, amend the spec in the same PR and call it out in the commit body.

**Next session starts with Mac Mini dogfood of HoloscapeClassic-live.**
