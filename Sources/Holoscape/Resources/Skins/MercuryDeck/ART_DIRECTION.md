# Mercury Deck Art Direction

`MercuryDeck` is now locked as the first vessel-driven hero skin.

This file freezes the composition so the work does not drift back into perimeter-frame decoration. The current shell PNGs are generated scaffolds, but they now express the required two-mass direction.

## Workflow Rule

- Do not start another shell-art pass until watcher cleanup is in place and this brief is the accepted source of truth.
- Do not spend time polishing a rounded-rectangle perimeter treatment.
- Build toward a vessel composition: left control spine, right screen body, strong seam, explicit traffic-light landing zone.

## Primary Composition

- The shell reads as two attached masses, not one rectangle with trim.
- Left side: vertical control spine with enough width and visual weight to own navigation and window controls.
- Right side: dominant screen body containing the main terminal cavity.
- Between them: an explicit mechanical seam. It should look intentional, engineered, and load-bearing, not like a faint divider line.
- Transparent negative space between the spine and body is allowed and expected; this is how the skin reads as extending outside the main text window while still living in one real macOS window.

## Channel Vessel Rules

- The channel vessel is a skinned reveal window for the existing channel list.
- First target is vertical only.
- Its gap from the screen body, height, vertical alignment, and signed offset are skin variables, not hardcoded controller behavior.
- Supported alignment language is deliberately simple: `top`, `center`, `bottom`, plus `verticalOffset` for hanging above/below or nudging inward.
- Build it with cap / stretch / cap logic.
- The middle span is the stretchable section.
- Most ornament belongs in the top cap, bottom cap, and anchor regions, not in the stretch zone.
- The silhouette can be pod-like, bezel-like, or console-like, but the list semantics remain a normal linear vertical list.
- The vessel should visually own the sidebar area rather than merely wrapping it.

## Screen Vessel Rules

- The screen body is calmer and more fixed than the control spine.
- The terminal cavity is the dominant focal mass.
- Treat the screen vessel as a display body with a stable bezel, not as another highly decorated sidebar-like object.
- A small top bridge, indicator shelf, or auxiliary display pocket is allowed, but the main screen remains the primary mass.

## Traffic-Light Landing Zone

- Reserve a stable traffic-light zone on the main text body, immediately to the right of the channel spine and seam.
- The main body should look designed around the controls rather than merely leaving room for them.
- The landing zone should visually align with the primary text window when the sidebar is expanded or when tabs move into the top strip.

## Input Panel Rules

- The input area should read as a separate adjustable-height drawer attached to the main text body.
- The resize affordance should be visible but restrained: a small grab groove, not a loud control.
- The input panel material must differ from both the channel vessel and the tab strip so the typing surface is legible as its own thing.

## Material And Color Rules

- Keep the restrained silver / graphite / smoked-glass direction unless the art direction is intentionally revised.
- Cyan and amber remain signal colors.
- Do not use cyan or amber as dominant large-area fills.
- Surface treatment should favor machined metal, dark glass, restrained glow, and small instrument accents over loud neon coverage.

## Animation Rules For The Next Pass

- Ambient only.
- Motion must not compensate for weak static composition.
- Acceptable motion: LEDs, subtle display shimmer, low-intensity undershine, restrained scan activity.
- Avoid aggressive sweeps, busy layered gadget motion, or many competing animated focal points.

## Immediate Implementation Target

- Keep the left vessel visually owning the sidebar region.
- Preserve the transparent separation between channel spine and screen body.
- Keep the right vessel visually calmer so the screen cavity stays primary, with the bottom input drawer as the only strong secondary panel.
