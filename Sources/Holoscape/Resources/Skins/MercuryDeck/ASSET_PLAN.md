# Mercury Deck Asset Plan

`Mercury Deck` is the first hero-skin scaffold: brushed aluminum, smoked glass, restrained cyan and amber instrumentation, and only ambient motion.

This directory is intentionally a scaffold, not finished art.

## Current State

- `skin.json` is production-shaped and points at real baked-chrome asset paths.
- The shell PNGs are generated from `tools/mercury_deck/generate_assets.swift` so the two-mass scaffold is reproducible.
- Decorative animation regions are ambient only.

## Required Shell Assets

These files are already wired in `skin.json` and must remain the authoritative shell entrypoints:

- `assets/chrome@2x.png`
- `assets/chrome-opaque@2x.png`

Regenerate from repo root with:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/holoscape-clang-cache swift tools/mercury_deck/generate_assets.swift
```

Final art expectations:
- logical chrome size: `1000 × 700`
- pixel size: `2000 × 1400`
- two-mass composition: left channel spine, transparent seam gap, right main text body
- input drawer carved into the bottom of the right main text body
- soft industrial shading, brushed metal grain, and restrained glass highlights

## Intended Coordinate Map

These are the regions the final art should respect.

- Full shell:
  - `0,0 → 1000,700`
- App interior:
  - `x: 16, y: 40, width: 968, height: 644`
- Left channel body:
  - `x: 4, y: 58, width: 242, height: 618`
- Right main body:
  - `x: 282, y: 8, width: 712, height: 684`
- Runtime vessel layout variables in `skin.json`:
  - `layout.vesselGap`: horizontal gap between channel/tab vessel and screen vessel
  - `layout.channelVessel.height`: side vessel visual height
  - `layout.channelVessel.verticalAlign`: `top`, `center`, or `bottom`
  - `layout.channelVessel.verticalOffset`: signed offset after alignment; positive top offset moves down, negative bottom offset hangs below
- Main traffic-light landing zone:
  - `x: 296, y: 16, width: 98, height: 30`
- Top instrument strip:
  - reserved visual band from `y: 0 → 40`
- Decorative display pocket:
  - `x: 684, y: 6, width: 126, height: 26`
- Status ladder:
  - `x: 828, y: 10, width: 126, height: 18`
- Bottom input drawer:
  - `x: 302, y: 596, width: 672, height: 76`

## First-Pass Art Rules

- Treat the shell as two attached hi-fi device masses, not a single perimeter frame.
- Keep art coordinates and `skin.json` layout variables in sync; if the side body moves, update `height`, `verticalAlign`, `verticalOffset`, and `vesselGap` rather than burying the change in code.
- Any meters, pods, vents, labels, or side modules are decorative only.
- The real app interior must remain dominant and readable.
- Avoid large saturated neon fills. Mercury Deck should feel premium, not loud.
- Default chrome controls remain detached traffic lights; the asset may paint a landing dock but must not paint fake replacements that fight the real buttons.

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
