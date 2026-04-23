# Holoscape Progress (2026-04-22)

## Current State

The chrome/vessel foundation is now stable enough to stop proving plumbing and start treating it as real product infrastructure.

What is true now:
- v4 chrome skins launch cleanly with the controller-owned app host mounted through `InteriorView`
- switching between borderless chrome mode and titled mode preserves a sane window hierarchy
- detached chrome traffic lights now close, minimize, and fullscreen correctly in chrome mode
- bundled directory skins and `.wamp` skins resolve watcher targets through the real active runtime path
- `MercuryDeck` now exists as the first vessel-driven hero-skin prototype with a channel vessel, screen vessel, and explicit seam
- the first runtime visual pass materially improved `MercuryDeck`, but it still reads as one framed device rather than two truly separate window masses

The project is no longer blocked on "can chrome mode and vessel layout work end-to-end?" The active conclusion is: "yes, the runtime foundation works, but the disjoint two-window illusion will require shell/silhouette art rather than more runtime-only tuning."

## Next Goal

Because the next day or two are short, shift back to programming work instead of continuing visual exploration.

Concrete target:
- land the current chrome/vessel milestone cleanly
- avoid more `MercuryDeck` runtime-art iteration until there is energy for a real shell pass
- use the stabilized host/vessel foundation for the next engineering task instead of reopening composition

## Next Order Of Work

1. Keep the current chrome-host + vessel milestone as the stable baseline
2. Do not spend time trying to fake a disjoint-window look through more interior styling alone
3. When returning to visual work later, treat the next `MercuryDeck` step as a shell/silhouette pass:
   shorter left outer mass, explicit transparent void, and a baked separation between the two bodies
4. Until then, focus on the next functional engineering task

## Do Not Drift Into

- another runtime-only `MercuryDeck` art loop
- trying to solve the two-window illusion without changing shell alpha/silhouette
- broad refactors unrelated to the current chrome/vessel milestone
- animation polish used to compensate for composition limits

## Constraints To Keep True

- one real Holoscape window with one real app interior
- vessel graphics frame existing Holoscape content; they do not replace app behavior
- detached traffic lights continue to behave like real window controls
- `MercuryDeck` remains the first vessel-driven hero skin, but its next major jump is a shell-art problem
