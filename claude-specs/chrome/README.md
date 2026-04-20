# Chrome Spec — PNG-alpha window architecture

**Status**: Pending — PRD approved, spec work not yet started.
**Supersedes**: `claude-specs/archive/amplify/` (shape + drag-region portions only; every v3 manifest capability survives)
**PRD**: `docs/png-chrome-prd.md`
**Investigation leading here**: `docs/research/shaped-window-transparency-findings.md` + `docs/research/shaped-window-architecture-prd.md`

## Starting point

The PRD describes a 7-day, 15-PR MVP. Spec work (requirements.md, design.md, tasks.md in Kiro format) has not been written yet. Next session: run `/spec` against the PRD to generate the three spec documents, then hand off to `/strategy` for PR-level decomposition.

## What the PRD commits to

- **Architecture**: `ChromeHostView` (single alpha-aware layer owns the window shape) + `InteriorView` (pinned to `interiorRect`, owns all app content by construction).
- **Authoring modes**: `baked` (ship `chrome@2x.png`) or `composed` (engine bakes from v3 surfaces at load time with SHA cache).
- **Hit testing**: `windowShape.polygons` + existing `HitRegionSampler` carry forward. No alpha sampling.
- **Validator**: cross-check `windowShape.polygons` matches chrome image's non-transparent bounds.
- **HiDPI**: `@2x` naming in MVP.
- **Backward compat**: v2/v3 skins continue to load; v4 opt-in via `chrome` manifest field.

## What gets deleted in MVP step 15 (after both in-tree skins migrate)

- `ShapedWindowController.buildMaskLayer` for content-view masking (moves to optional `InteriorView.layer.mask` for concave interiors only)
- `WindowDragOverlay` (replaced by `isMovableByWindowBackground` + chrome alpha)
- Polygon scaling + `windowDidResizeForShape` observer (PNG chrome is fixed-size by construction)
- `writeShapeDiagnostic` infrastructure from the investigation branch (never merged to main)
