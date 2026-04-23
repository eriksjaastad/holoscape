# Skin Roadmap

Concrete roadmap for turning Holoscape's skinning engine into a set of real, shippable skins.

This document is intentionally narrower than the PRDs and implementation plans. It answers:
- which skins we should build
- in what order
- why that order makes sense
- where animation fits in each step

It assumes the current v4 chrome foundation is working and stable enough to support real skin production.

## Product Goal

Holoscape should ship with a small set of skins that feel like identities, not color themes.

The first milestone is not "support every possible skin." The first milestone is:
- one excellent daily-driver skin
- one or two follow-up skins with clearly different visual languages
- a repeatable authoring pattern for future skins

## Constraints

The current engine supports:
- one main window shell
- one real app interior via `interiorRect`
- baked or composed chrome
- ambient animation overlays
- sprite-backed controls and decorative motion

The current engine does not yet support:
- many independently interactive mini-windows
- arbitrary multi-panel desktop layouts inside one skin
- full Winamp-style scripted behavior

So every candidate below is designed as:
- one sculpted shell
- one real viewport
- optional fake or decorative subdevices around it

## Skin Tiers

### Tier 1: Hero Skins

These are the skins that should feel product-defining and user-facing.

### Tier 2: Engineering Reference Skins

These prove engine capabilities, maintain backward compatibility, and exercise specific subsystems.

Current Tier 2 skins:
- `HoloscapeClassic-live`
- `HoloscapeSynthwave`
- `AmplifyDemo`

They should remain in-tree, but they are not the full answer to "what skins ship as the product face of Holoscape?"

## Selection Criteria

A skin is a good roadmap candidate if it:
- clearly differs from the others in silhouette, texture, and mood
- fits the current single-window architecture
- can be daily-driven for terminal work
- benefits from ambient animation without requiring heavy animation
- teaches something reusable about the authoring pipeline

## Named Candidate Skins

### 1. Mercury Deck

Visual direction:
- brushed aluminum hi-fi module
- machined knobs, vents, smoked glass, instrument labels
- cool silver base with restrained cyan and amber accents

Why it should exist:
- easiest path to a believable "real object" shell
- fits the existing single-window model cleanly
- likely to feel premium and usable even with modest art

Recommended mode:
- `baked`

Animation posture:
- subtle meter flicker
- small status LEDs
- low-frequency glass glow
- optional scanline or shimmer in decorative display windows

Why it is first:
- lowest art-direction risk
- easiest to keep readable and daily-drivable
- best candidate for proving that Holoscape can ship one serious skin now

### 2. Signal Bloom

Visual direction:
- retro-futurist broadcast console
- warm orange, red, and cream display islands
- radar sweeps, indicator lamps, signal scopes

Why it should exist:
- introduces warmth and personality after a cooler metal-first skin
- closer in spirit to "gadget collage" without requiring many real subwindows
- strong fit for decorative animated instruments

Recommended mode:
- `baked`

Animation posture:
- pulsing lamps
- slow sweep shader in one or two circular display pockets
- scrolling ticker or LCD marquee

Why it is second:
- still compatible with the current shell model
- pushes the animation language further
- tests whether we can make a skin feel playful without becoming chaotic

### 3. Neon Circuit

Visual direction:
- black composite shell with inset neon channels
- cyan, acid green, magenta edge-lighting
- sharper geometry and more visible energy flow

Why it should exist:
- gives Holoscape a more overtly cybernetic / hacker identity
- easier to author as a hybrid of composed surfaces plus a smaller baked shell
- works well as a "high-energy" counterpart to Mercury Deck

Recommended mode:
- `composed` first, optionally `baked` later

Animation posture:
- animated border glow
- light pulses along channels
- sparse particles and interference shimmer

Why it is third:
- valuable as a lighter-weight authoring template
- good test of how far composed skins can go before needing fully baked artwork

### 4. Cathedral Engine

Visual direction:
- dark ceramic or obsidian shell
- luminous internal windows, halo rings, ritual-machine typography
- more atmospheric and less industrial

Why it should exist:
- proves Holoscape skins do not need to be literal hardware
- expands the emotional range beyond synthwave and hi-fi machinery
- good target for shader-led ambience

Recommended mode:
- `baked`

Animation posture:
- breathing halo light
- drifting particulate fog or embers
- low-speed pulse fields behind decorative glass

Why it is fourth:
- stronger aesthetic payoff, but art direction is harder
- riskier to keep readable
- better once the first two or three skins have hardened the authoring workflow

### 5. Dockyard Utility

Visual direction:
- rugged industrial service panel
- labels, fasteners, warning paint, maintenance hatches
- more utilitarian than theatrical

Why it should exist:
- strong daily-driver option for users who want "custom" but not flamboyant
- useful balance against more expressive skins
- likely to age well as a default-alt skin

Recommended mode:
- `baked`

Animation posture:
- almost none by default
- very restrained status blink and panel glow

Why it is fifth:
- less likely to create product buzz as the first showcase skin
- still valuable once the line starts to become a skin family

## Ordered Build Sequence

### Phase 0: Keep the fixtures

Do not replace the current engineering fixtures yet.

Keep:
- `HoloscapeClassic-live`
- `HoloscapeSynthwave`
- `AmplifyDemo`

Purpose:
- regression coverage
- engine capability proof
- animation smoke coverage

### Phase 1: Build one hero skin

Build:
- `Mercury Deck`

Definition of done:
- production-quality shell art
- stable `baked` chrome manifest
- one polished ambient animation package
- controller/integration/UI verification on the same paths already used for current skins

This is the first real "ship it and use it every day" skin.

### Phase 2: Add a more expressive second skin

Build:
- `Signal Bloom`

Purpose:
- widen the emotional range
- prove the system can support a warmer, more playful visual language
- establish a second animation vocabulary beyond the first hero skin

### Phase 3: Add a lighter-weight authoring template

Build:
- `Neon Circuit`

Purpose:
- create the best composed-first template
- lower the cost of future skins
- prove not every future skin requires the full baked-art pipeline

### Phase 4: Add one atmospheric prestige skin

Build:
- `Cathedral Engine`

Purpose:
- push mood and ambience
- test deeper animation layering
- expand the aesthetic brand of Holoscape beyond "retro hardware"

### Phase 5: Add one restrained utility skin

Build:
- `Dockyard Utility`

Purpose:
- provide a calmer alternative
- round out the lineup with a more practical long-session option

## Animation Roadmap Within The Skin Roadmap

Animation stays on the roadmap from the start, but it should deepen in stages.

### Animation in Phase 1

Allowed:
- ambient glow
- small status lights
- one marquee or meter effect
- low-distraction motion only

Goal:
- make the first hero skin feel alive without making motion the whole point

### Animation in Phase 2 and 3

Expand to:
- more visible display widgets
- better state-linked motion
- stronger distinction between "hero" skins and quieter skins

Goal:
- establish repeatable motion language and reusable presets

### Animation in Phase 4 and beyond

Expand to:
- layered ambient systems
- mood shifts across multiple surfaces
- richer chrome/shader coordination
- more expressive instrument-style reactive elements

Goal:
- make animation part of the identity of Holoscape skins, not just decoration

## Production Strategy Per Skin

Every hero skin should follow the same sequence:

1. Pick the shell concept and one-sentence emotional target.
2. Decide `baked` versus `composed`.
3. Lock the `interiorRect` early so the shell is designed around the real viewport.
4. Build the static shell first.
5. Add decorative fake devices and labels second.
6. Add one small animation package third.
7. Dogfood for actual terminal work before expanding detail.

This order matters. A skin that looks exciting in a mockup but is miserable to use is not a successful Holoscape skin.

## Asset Expectations

For the first three roadmap skins, expect:
- one master shell image for each baked skin
- supporting sprite sheets for small controls or indicators
- 1-3 decorative animation regions per skin
- no attempt at many independently interactive mini-panels

This keeps the art workload realistic while still making the skins feel ambitious.

## Suggested Ownership / Sequencing

### Immediate

- build `Mercury Deck`
- treat it as the canonical V1 hero skin
- use it to improve docs, templates, and validation

### Next

- build `Signal Bloom`
- extract reusable animation patterns from both hero skins

### Then

- build `Neon Circuit`
- use it as the authored template for future lower-cost skins

### After that

- choose between `Cathedral Engine` and `Dockyard Utility` based on what feels missing in the lineup

## Decision Rule

If the team can only afford one new skin soon, build `Mercury Deck`.

If the team can afford two, build:
1. `Mercury Deck`
2. `Signal Bloom`

If the team wants the best long-term pipeline, build:
1. `Mercury Deck`
2. `Signal Bloom`
3. `Neon Circuit`

That gives Holoscape:
- one premium daily-driver
- one expressive showcase skin
- one lower-cost template skin

## Bottom Line

The roadmap should not try to recreate classic Winamp skin chaos all at once.

The right move is:
- first prove one unforgettable shell
- then prove range
- then prove repeatability

That sequence is the shortest path from a working engine to a real skin product.
