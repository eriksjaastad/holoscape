# Mercury Deck Asset Plan

`Mercury Deck` is the first hero-skin scaffold: brushed aluminum, smoked glass, restrained cyan and amber instrumentation, and only ambient motion.

This directory is intentionally a scaffold, not finished art.

## Current State

- `skin.json` is production-shaped and points at real baked-chrome asset paths.
- The current shell PNG placeholders are borrowed from `HoloscapeClassic-live` so baked-mode loading, validation, and controller wiring can be exercised immediately.
- Decorative animation regions are ambient only.

## Required Shell Assets

These files are already wired in `skin.json` and must remain the authoritative shell entrypoints:

- `assets/chrome@2x.png`
- `assets/chrome-opaque@2x.png`

Final art expectations:
- logical chrome size: `1000 × 700`
- pixel size: `2000 × 1400`
- one-shell composition with the viewport cut into the shell, not floating above it
- soft industrial shading, brushed metal grain, and restrained glass highlights

## Intended Coordinate Map

These are the regions the final art should respect.

- Full shell:
  - `0,0 → 1000,700`
- App interior:
  - `x: 16, y: 40, width: 968, height: 644`
- Top instrument strip:
  - reserved visual band from `y: 0 → 40`
- Decorative display pocket:
  - `x: 684, y: 6, width: 126, height: 26`
- Status ladder:
  - `x: 828, y: 10, width: 126, height: 18`
- Bottom undershine / footlight:
  - `x: 0, y: 656, width: 1000, height: 44`

## First-Pass Art Rules

- Treat the shell as a single hi-fi device, not a collage of many independent windows.
- Any meters, pods, vents, labels, or side modules are decorative only.
- The real app interior must remain dominant and readable.
- Avoid large saturated neon fills. Mercury Deck should feel premium, not loud.
- Default chrome controls remain detached traffic lights; do not paint fake replacements that fight them.

## Planned Supporting Assets

These are likely follow-up assets once the shell art exists:

- LED strip or indicator sprite sheet for richer top-band status lights
- small display/meter sprite sheet if the decorative pocket moves beyond a shader-only treatment
- optional label/font assets if the shell gains engraved legends or panel text

## Animation Direction

Mercury Deck is ambient-first.

Keep:
- low-frequency glow
- subtle status-light motion
- restrained display shimmer or scan

Avoid for the first polished pass:
- large sweeping particles
- aggressive marquee motion
- many independent animated devices competing for attention
