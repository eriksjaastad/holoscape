# SkinEngine audit (#5888)

Status: implementation audit and keep/replace decision for the existing skin stack.

## Decision

Keep the current SkinEngine/Chrome v4 stack as the base and finish the missing wiring in small reliability slices. Do not replace it with a new skin runtime.

Reason: the existing implementation already has the hard pieces that matter for a daily-driver terminal: sandboxed asset resolution, process-scoped font registration, bundle/user skin resolution, hot-reload watching, alpha-window reconstruction, chrome bake caching, manifest validation, density/reduce-motion hooks, and unit coverage across the load/validation/rendering seams. Replacing it now would discard working reliability infrastructure and delay the tank-backend roadmap.

## Current architecture

### Manifest generations

`Sources/Holoscape/Models/SkinDefinition.swift` supports additive generations:

- v1: flat color/image fields applied through `AppearanceConfig`.
- v2: `surfaces` dictionary resolved into `SkinContext` surface appearances.
- v3 / Amplify: `windowShape` and `dragRegions` for shaped windows and drag handles.
- v4 / PNG-alpha chrome: optional `chrome: ChromeDescriptor?`, routing through `ChromeHostView` + `InteriorView`.
- v4.1: optional `layout: SkinLayoutDescriptor?` for channel/screen vessels.

The backward-compatibility invariant is sound: absent newer fields preserve older rendering paths.

### Load path

`Sources/Holoscape/Services/SkinEngine.swift` owns the load pipeline:

1. enumerate bundled and user skins, including `.wamp` bundles;
2. resolve user overrides before bundled skins;
3. decode `skin.json`;
4. validate and load image assets inside the skin sandbox;
5. load ninepatch sidecars;
6. convert v2 surfaces into `SkinContext.ResolvedSurface` values;
7. validate v3 window shape and drag regions;
8. bake/validate v4 chrome when present;
9. register fonts last so earlier failures do not leak process-scoped fonts;
10. return a single `LoadedSkin` value consumed by `MainWindowController`.

This should stay. It gives the app one atomic load result and keeps picker, launch persistence, and hot reload from diverging.

### Chrome v4 path

The v4 path is split cleanly:

- `ChromeBakePipeline` decodes baked PNG chrome or composites v3 surfaces into a Base_Layer image, computes a deterministic SHA, writes best-effort cache entries, handles corrupt cache deletion, and creates Reduce Transparency variants.
- `ChromeManifestValidator` enforces fatal and non-fatal manifest checks: RGBA alpha, 2x image dimensions, `interiorRect` bounds, small-size warnings, polygon/alpha bbox delta, animation ids, rect bounds, z-order, shader presets, and animation asset existence.
- `MainWindowController+ChromeMode` reconstructs a new borderless transparent window instead of trying to retrofit transparency into a titled window, installs `ChromeHostView`, `InteriorView`, silhouette masking, drag handles, and detached traffic-light controls.
- `ChromeHostView` paints Base_Layer and owns the animated-layer container/mask. It never accepts hit testing, so terminal/app content stays in the interactive path.

This is the right shape for a self-contained terminal: skins can be visually wild, but terminal content remains in ordinary app views and the chrome branch has explicit fallback behavior.

## Keep

Keep these pieces with only focused hardening:

- `SkinEngine.loadComposite(named:)` as the single authoritative skin load transaction.
- User-over-bundle skin precedence and `.wamp` support.
- Asset sandbox gates in `validateAssetPath` and `assertPathResolvesInside`.
- Process-scope font registration/deregistration via `SkinFontBundle`.
- Bundled reference skins under `Sources/Holoscape/Resources/Skins`.
- Chrome bake cache keyed by deterministic SHA.
- Chrome manifest validator as the fail-closed load gate.
- Window reconstruction for v4 chrome mode; do not reintroduce property-flip transparency hacks.
- `ChromeHostView` as non-interactive chrome-only sibling of `InteriorView`.
- Density mode and Reduce Motion concepts; they align with backend-first reliability because visual cost can be disabled without changing terminal state.

## Replace / remove later

Do not replace the whole engine. Replace or delete only these narrower items as follow-up work:

1. **Stale rollout comments.** Several comments still describe future PR numbers even though much of the code exists. Replace PR-number language with state-based comments so future workers do not treat implemented code as a stub.
2. **Legacy v3 shaped-window path after v4 coverage is complete.** `ShapedWindowController` / old CA-mask path should remain until all in-tree skins and tests prove v4 parity. Delete only after a focused removal card.
3. **Manifest-time animation asset checks split across overloads.** `ChromeManifestValidator` has a no-`skinDir` path plus a `skinDir` overload that adds asset existence checks. This is acceptable for tests, but production should eventually use one explicit validation context object to avoid split-brain checks.
4. **Sprite animation sheet plumbing.** `ChromeHostView.makeRenderer` currently constructs `SpriteAnimLayerRenderer` with `sheet: nil`, so sprite animation descriptors validate but cannot draw their sheet yet. Finish this before treating animated chrome as production-complete.
5. **Chrome host hot-reload diff.** `ChromeHostView.diffAnimatedLayers(_:)` is still TODO. Without it, chrome hot reload cannot update animation layers in place.
6. **Runtime accessibility hooks.** `MainWindowController.updateDensityModeOnChrome(_:)` and `handleReduceMotionChange()` are TODO stubs. Wire them before heavy animated skins ship.
7. **Composed-mode ninepatch parity.** `ChromeBakePipeline.paintBand` falls back to stretch for ninepatch image fills and notes sidecar propagation as future work. Finish or explicitly document the limitation for composed-mode skins.

## Risks

- **Skin code has more breadth than the tank-backend phase wants.** The stack is powerful enough to distract from session/process reliability. Keep new skin work limited to correctness/audit/hardening until core terminal phases are stable.
- **Fallbacks must stay loud.** Chrome bake/validation failures intentionally fall back to rectangular/v3 rendering. That is safe only if the warning banner remains visible and test-covered.
- **Comment drift can mislead workers.** Many files contain historical PR rollout notes. The implementation appears ahead of those comments in places.
- **Animations can become a hidden CPU/GPU tax.** Density mode and Reduce Motion hooks exist conceptually, but runtime wiring must be finished before animated skins are considered safe by default.

## Tests and coverage found

Relevant unit/UI coverage exists for:

- `SkinEngineLoadCompositeTests`
- `SkinEngineAssetLoadingTests`
- `SkinEngineFontRegistrationTests`
- `SkinEngineDensityGateTests`
- `SkinContextResolutionTests`
- `SkinDefinitionV2Tests`
- `SkinDefinitionErrorTests`
- `SkinLayoutDescriptorTests`
- `ChromeDescriptorCodableTests`
- `ChromeBakePipelineTests`
- `ChromeManifestValidatorTests`
- `ChromeHostViewTests`
- `MainWindowControllerChromeBranchTests`
- renderer tests for particle, LED, sprite, and shader layers
- `BundledSkinTests`
- `SkinEngineUITests`

This is enough to justify hardening in place rather than rewriting.

## Recommended next card split

1. **Skin comment cleanup / audit closeout:** remove stale PR-number rollout wording where it contradicts implemented state.
2. **Animated chrome runtime wiring:** sprite sheet resolution, density/reduce-motion hooks, and `diffAnimatedLayers`.
3. **Composed-mode parity:** ninepatch sidecar support in `ChromeBakePipeline` or a documented non-goal.
4. **Legacy path retirement gate:** create a checklist for deleting the old CA-mask path only after all bundled skins and UI tests pass in v4 mode.

## Acceptance for #5888

- Existing SkinEngine architecture audited: complete.
- Keep/replace decision recorded: keep and harden in place.
- Follow-up risks and implementation gaps listed with concrete files: complete.
- No production code changed by this card: intentional; this is an audit card.
