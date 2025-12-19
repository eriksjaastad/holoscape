# Skin Ideas

**Visual inspiration and concepts for Hologram skins**

---

## Skin Generator Agent (Future Tool)

**Idea:** An AI agent that dreams up skin concepts on demand.

### How It Works
- Feed it a reference or mood: "Westworld meets vaporwave" or "cozy library at night"
- It generates a complete skin concept:
  - Window shape description
  - Color palette (hex codes)
  - Particle behavior (physics, speed, patterns)
  - Typography suggestions
  - Sound design notes
  - Personality prompt for the AI

### Why This Is Useful
- Creative block is real — "what should this look like?" is hard
- The generator can produce 10 concepts in a minute
- You pick the ones that spark something, discard the rest
- Also tests the skin format — if an AI can generate valid skins, the format is clean

### Implementation Ideas
- Could be a standalone script that outputs skin manifests
- Could be integrated into Hologram as a "Generate Skin Idea" button
- Could run in background, collecting concepts while you build

**Status:** Future side project. Document in roadmap so we don't forget.

---

## Philosophy

The skin system isn't just visual themes — it's personalities. Each skin changes:
- Window shape
- Color palette
- Particle behavior
- Typography
- Sound effects (optional)
- AI personality prompt

The **default skin** should be a blank canvas. Wild skins live in the skin library.

---

## Default Skin: "Origin"

**Philosophy:** Simple, but deep. Like the original iPod — restrained on the surface, magical underneath.

### Visual Concept
- **Shape:** Soft rounded rectangle — calm, not wild
- **Palette:** Monochromatic warmth — off-white, warm grey, subtle
- **Typography:** Clean, modern, with good bones — no sci-fi fonts
- **Chrome:** Minimal — no gradients, no glows, no "look at me"

### Particle Behavior
- Barely visible — like dust motes in a sunbeam, drifting
- When typing: particles subtly gather toward input area
- When thinking: slow, quiet tightening into a gentle pulse
- Transitions feel like breathing, not snapping

### The Vibe
You open it, it's calm, it's just... there. And then you notice the particles. And you watch them for a second. And you realize they're responding to something. It's not performing — it's just being what it is.

### Why This Works
The default is the statement: "This is a canvas. Here's what a gentle brushstroke looks like. Now imagine what else you could do."

Wild skins work *because* the default is restrained.

---

## Inspiration: Modern TV Intros

High-end motion graphics from title sequences — precision, elegance, "impossible" visuals.

### Westworld (HBO)
- Mechanical precision, milk-white androids, piano playing itself
- Organic forms emerging from technological processes
- Clinical elegance, exposed mechanism
- Circular/radial motifs (the eye with rings)
- **For Hologram:** Particles that resolve into geometric forms when thinking — like crystallizing a thought

### Foundation (Apple TV)
- Mathematical, cosmic, particles forming equations
- "The universe is math" energy
- Shapes dissolving into dust
- **For Hologram:** Particles with mathematical precision, orbital mechanics

### Severance (Apple TV)
- Surreal, office furniture morphing
- Disorienting scale shifts
- "Something is wrong here" energy
- **For Hologram:** Unsettling particle behavior for a darker skin theme

### His Dark Materials
- "Dust" — particles forming and reforming
- Ethereal golden quality
- **For Hologram:** Warm, golden particles with intentional movement

### True Detective S1
- Double exposure, landscape overlaid on faces
- Ghostly, layered
- **For Hologram:** Layered particle systems, depth

---

## Skin Concepts

### "Cortana" (Halo-Inspired)
- **Shape:** Organic, biomorphic curves
- **Palette:** Blue/purple gradient, cyan accents
- **Particles:** Active, responsive, holographic shimmer
- **Personality:** Brief, military, slightly sarcastic
- **Vibe:** "Chief... I mean, Erik."

### "Westworld"
- **Shape:** Precise geometric, mechanical feel
- **Palette:** White, cream, subtle gold accents
- **Particles:** Synchronized orbital mechanics, mathematical
- **Personality:** Clinical, observant, unsettling calm
- **Vibe:** "These violent delights have violent ends."

### "Foundation"
- **Shape:** Circular, cosmic
- **Palette:** Deep space black, star white, equation blue
- **Particles:** Cosmic dust forming mathematical patterns
- **Personality:** Ancient, prophetic, speaks in patterns
- **Vibe:** "Psychohistory predicts..."

### "Wizard" (Archaic)
- **Shape:** Organic, flowing robes silhouette
- **Palette:** Deep purple, gold, parchment
- **Particles:** Magical sparkles, slow swirls
- **Personality:** Verbose, mystical, archaic English
- **Vibe:** "Hark, my pupil..."

### "Minimal"
- **Shape:** Perfect circle or pill
- **Palette:** Pure black and white
- **Particles:** Almost invisible, barely there
- **Personality:** No personality — just answers
- **Vibe:** Pure utility with a hint of style

### "Neon" (Cyberpunk)
- **Shape:** Angular, aggressive cuts
- **Palette:** Hot pink, electric blue, warning yellow
- **Particles:** Glitch effects, scanlines, data streams
- **Personality:** Street-smart, irreverent, uses slang
- **Vibe:** "Choom, let me tell you..."

### "Projector" (R2D2 / Star Wars Hologram) ⭐ PRIORITY
- **Layout:** Completely different structure
  - **Bottom:** Dark rectangular plinth/base (where you type)
  - **Above:** Hologram "projects" upward from the base
  - Like R2D2 projecting Princess Leia
- **Shape:** Base is flat rectangle; hologram area is ethereal, no hard edges
- **Palette:** Blue-white holographic glow, dark matte base
- **Particles:** Rise upward from base, form the hologram shape, flicker slightly
- **Scan lines:** Subtle horizontal interference, like analog projection
- **Input area:** Looks like a control panel on the plinth
- **Personality:** Droid-like helpfulness, occasional beeps translated to text
- **Vibe:** "I've got the data you requested, Master Erik."

**Why this is great:**
- Strong visual metaphor (projector → projection)
- Natural separation: input below, output above
- Particle direction has meaning (rising = generating)
- Iconic reference everyone recognizes
- Actually functional — text area is clearly a "panel"

### "Steamwork" (Steampunk)
- **Shape:** Brass porthole, rivets around edges, asymmetric
- **Palette:** Copper, brass, aged leather brown, steam white
- **Particles:** Steam wisps, tiny gears floating, sparks
- **Textures:** Brushed metal, worn leather, glass gauges
- **Animation:** Gears rotate slowly in background, steam vents when thinking
- **Typography:** Serif, Victorian, slightly weathered
- **Personality:** Formal, Victorian English, refers to "the mechanism"
- **Vibe:** "The analytical engine has processed your query, good sir."

**Design notes:**
- The "thinking" state could show pressure gauges rising
- Steam vents when it starts responding
- Subtle ticking/clicking sounds (optional)
- Could have a small "furnace" glow when active

---

## Technical Patterns to Explore

### Particle Effects
- Wireframe-to-solid transitions
- Subsurface scattering (milky, translucent look)
- Mechanical reveals (layers peeling back)
- Physics-based flocking/swarming
- Voronoi/cellular patterns
- Metaball/blob effects

### Window Shapes
- Pure circle (bold statement)
- Organic blob (Sonique tribute)
- Hexagonal (sci-fi)
- Asymmetric (unsettling)
- Pill/capsule (modern, friendly)
- Circular with notch (like classic Sonique)

### Animation Principles
- Slow, deliberate motion — nothing fast or flashy
- Everything precise, intentional
- State transitions that feel "designed"
- Particles with apparent purpose

---

## Research: Sonique Skins

Sonique had wild, non-rectangular shapes in 1999-2001. Study:
- How they handled hit testing on curved edges
- Their skin file format
- Community skin galleries (archive.org)
- What made them memorable vs. forgettable

**Key question:** How did they make the shape feel intentional rather than gimmicky?

---

## Success Criteria for Skins

A skin is successful when:
- [ ] The shape feels intentional, not random
- [ ] Particles enhance mood without distracting
- [ ] Typography is readable despite stylization
- [ ] Personality prompt matches visual aesthetic
- [ ] Someone sees a screenshot and asks "what IS that?"

A skin has failed when:
- [ ] It looks like a rectangle with rounded corners
- [ ] Particles are annoying or distracting during actual use
- [ ] Text is hard to read
- [ ] Personality feels disconnected from visuals

---

*Last updated: December 20, 2025*
*Status: Collecting inspiration, refining concepts*


