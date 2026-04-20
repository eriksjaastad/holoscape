# Holoscape — Session Progress (2026-04-20, end of day)

## TL;DR FOR NEXT SESSION

1. Chrome v4 corners still render opaque. Fix is scoped and research-backed.
2. Read `docs/research/chrome-transparency-root-cause.md` first — everything else is context.
3. The one-line answer: add a `CAShapeLayer` mask to `shapedContent.layer` in `applyChromeSkin` using `ShapedWindowController.buildMaskLayer` with a rounded-rect path matching `chrome.width × chrome.height` + 16pt corner radius. Also set `hasShadow = true` and use styleMask `[.borderless, .resizable]` (NOT `.fullSizeContentView`).
4. Expected scope: 30–60 min if nothing surprises.
5. Current branch: `fix/chrome-reparent-subviews` — has uncommitted-but-now-committed work-in-progress fixes (reparent bug fix, chrome PNG corner-painting fix, explicit `.clear` layer backgrounds per canonical recipe, diagnostic logging, spec amendments, root-cause doc).
6. After the fix works, clean up: revert the diagnostic `diagnoseChromeTransparency` logging; then reconsider PR #20 cleanup with `buildMaskLayer` KEPT.

**Skill pipeline also hardened today** (`/strategy`, `/spec`, `/trace`, `/propose`) so this failure mode can't happen on other projects. See each skill's SKILL.md for the Platform-Level Risk Validation gates. Independent of Holoscape; done and shipped.

## START HERE — READ THE CORRECTION BELOW FIRST

**Session 1 status (morning → afternoon)**: 19 of 20 chrome PRs merged. Infrastructure (data model, views, bake pipeline, validator, mode branch, drag, RT, animations, reference skins, docs, BC tests, debug overlay) all shipped and tested. **896 unit tests green.**

**Session 2 status (afternoon live test)**: Launched `HoloscapeClassic-live`. Cut corners render **opaque charcoal, not transparent**. 5+ hours of Swift-side fixes (explicit clear layer backgrounds, frame-view fix, explicit `isOpaque=false` on every layer, etc.) changed nothing. Erik correctly called this out as flailing and asked for actual research.

**Root cause identified 2026-04-20 evening**: the core assumption of the entire 20-PR plan was wrong. Full writeup: **`docs/research/chrome-transparency-root-cause.md`**.

- The Risk #1 finding ("borderless-from-birth + PNG alpha = transparent corners") was based on a confounded isolation test that had inherited state from a previous CA-mask install. The test was not clean.
- **PNG `layer.contents` alpha does NOT clip an `NSWindow`'s backing store.** The canonical mechanism — used by every documented shaped-window implementation on macOS (hfyeomans/winamp-macos-migration, CocoaDev, Matt Gallagher cocoawithlove) — is a **`CAShapeLayer` mask on `contentView.layer`**. PNG alpha provides visuals inside the clipped region; the mask defines the region.
- Our chrome-mode branch (`applyChromeSkin` in PR #6/#153) installs no mask. That's why corners render opaque.
- `ShapedWindowController.buildMaskLayer` — which the spec scheduled for deletion in PR #20 — is actually the load-bearing piece.

**Next session**:
1. Read `docs/research/chrome-transparency-root-cause.md` first.
2. Implement the fix: `applyChromeSkin` installs a `CAShapeLayer` mask on `shapedContent.layer` using `buildMaskLayer` with a silhouette path derived from `chrome.width × chrome.height` + 16pt corner radius. Also: styleMask `[.borderless, .resizable]` (NOT `.fullSizeContentView`), `hasShadow = true`. Expected scope: ~30 min of code, not another 8 hours.
3. Relaunch, verify transparent corners.
4. THEN reconsider PR #20 cleanup — `buildMaskLayer` stays (amended), `WindowDragOverlay` + polygon scaling probably still safe to remove.

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
