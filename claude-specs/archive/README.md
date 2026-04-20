# Archived Specs

Specs that have been superseded and no longer drive active work. Kept for historical reference only — **do not add new tasks here, do not rely on these for current architectural decisions.**

## amplify/

**Superseded: 2026-04-20**
**Replaced by**: `claude-specs/chrome/` (follows `docs/png-chrome-prd.md`)

Amplify v1 shipped the v3 skin manifest (sprite sheets, font consumption, border/corner/shadow on individual chrome surfaces, `.wamp` bundle format, keyable borderless windows, fixed-size shape windows, hit sampling, drag regions, malformed-skin banner). All of that infrastructure ships on `main` and is carried forward.

What Amplify v1 did NOT ship: actual window-level transparency at cut corners. The `CALayer.mask` polygon approach was investigated extensively (see `docs/research/shaped-window-transparency-findings.md`) and found to be fundamentally incompatible with Holoscape's view tree — descendant opaque layers paint through parent masks, contradicting Apple's CA documentation, and no authoritative source explaining the behavior was found.

Pivoted to the "one alpha-aware renderer owns every visible pixel" architecture (the approach Winamp, Spotify, OmniGraffle, Sketch all use). New spec work tracks at `claude-specs/chrome/`.
