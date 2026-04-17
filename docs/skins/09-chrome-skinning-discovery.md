# Discovery Brief — Chrome Skinning System

**Date:** 2026-04-16
**Status:** Ready for `/strategy`

## The Idea

A Winamp-inspired chrome skinning system for Holoscape that transforms the terminal's surrounding UI (sidebar, borders, tab bar, status area) with custom visual assets — static textures, animated effects, and AI-generated designs. The terminal content stays functional; the chrome around it becomes a canvas for creative expression.

## The Real Why

Holoscape exists because every AI terminal (ChatGPT, Claude, Warp, iTerm) is boring. The entire product thesis is: **why can't a terminal be fun?** Chrome skinning is the core differentiator — not a feature, the whole point. Erik wants to look at his terminal and feel something. "The Crisis of terminals" — like Crysis pushed hardware limits for games, Holoscape pushes them for terminals. "The 45-second Flash intro of terminals."

Secondary motivation: nostalgia and joy for 40-50 year olds who remember Winamp. Free forever. No monetization.

## Expert Panel Used

| Lens | Key Finding |
|------|-------------|
| Domain Expert (Winamp) | Classic skins succeeded via fixed regions + bitmap swap (65k skins). Modern skins (XML + MAKI scripting) killed the ecosystem with complexity. The constraint enabled scale. |
| UX Advocate | Beauty vs readability is a real tension. Solved by Reader Mode: a minimal floating pane over a dimmed/paused Holoscape. Also solved by three skin density modes (full/minimal/off). |
| AI/Creative Technologist | AI skin generation from reference images or text prompts. Local image generation (Stable Diffusion on Apple Silicon). Skin builder as a built-in module (pluggable, can be removed). |
| Infrastructure Realist | `.hsk` ZIP format: PNGs for chrome regions + `skin.json` manifest + optional GLSL shaders. 9-slice scaling for resolution independence. Four collapsible regions (top/right/bottom/left). |

## Strengths

- **Unique positioning.** No terminal app has anything close to Winamp-style skins, let alone AI-generated skins.
- **Existing infrastructure.** The shader pipeline (cards 1-6, PRs #76-#89) already provides Metal rendering, GLSL compilation, and per-frame display link compositing. Chrome skinning layers on top of this, not from scratch.
- **The reader mode concept.** Elegantly resolves the "cool skin vs readable text" tension. Purpose-built: no navigation, no structure, just text. Floats over dimmed Holoscape. Dismissing it restores full skin glory with animations.
- **Collapsible regions.** Same skin adapts from laptop (thin left sidebar only) to big monitor (full blast, all four sides, animations).
- **AI competition mode.** "Here's my design, now you make one that beats it." Genuinely fun, genuinely unique.

## Blind Spots Identified

- **Chrome rendering engine is entirely new.** Shaders process terminal content; chrome skinning is CALayer-based compositing of PNG assets around the terminal with 9-slice scaling. Different system, different code.
- **Skin builder scope.** Built as a native module inside Holoscape (designed to be pluggable/removable). Local image generation is computationally heavy (~30-60s per image on Apple Silicon). Fine for a builder workflow, not live iteration.
- **Terminal shader capture still has a bug.** iChannel0 (terminal content texture) renders black in the live app despite passing in offscreen tests. The sampler fix (PR #87) is merged but untested visually with the scanlines shader. Chrome skinning doesn't depend on this but the shader pipeline needs it resolved.
- **Xcode project out of sync with SwiftPM.** XCUITests (including the new ShaderVisualTests) can't build under `xcodebuild` until `.xcodeproj` includes all SwiftPM-managed sources. Card #5988 filed.

## Conflicts Between Lenses

- **Domain Expert vs AI Technologist:** Winamp's success came from a dead-simple fixed template that anyone could paint in Photoshop. AI generation is the opposite — high-capability, high-complexity. Resolution: the `.hsk` format should be simple enough that a human CAN hand-build a skin (PNGs in a ZIP), but the skin builder makes it easy via AI.
- **UX Advocate vs Creative Vision:** Readability vs beauty. Resolution: three-tier system (full/minimal/off skin modes) plus reader mode overlay.

## Open Questions

1. **Sidebar element restyling.** When the sidebar is skinned, do the tab indicators become part of the skin (custom shapes, LEDs, dots) or do the existing UI elements just get a chrome border? Erik's answer: the indicators themselves should be fully customizable — "glowing dots, big square buttons, they could take on all kinds of forms." Scrollable always.
2. **Skin + shader interaction.** A skin should be able to include both chrome PNGs AND a terminal shader. They're independent layers — chrome wraps the frame, shader processes the content inside.
3. **Skin builder architecture.** Built into Holoscape as a native module, designed to be pluggable so it can be removed if someone doesn't want the overhead.

## Scope Assessment

**Quarter-scale project.** Three major deliverables:

1. **Chrome Rendering Engine** — `.hsk` format, 9-slice compositor, four collapsible regions (top/right/bottom/left), three density modes (full/minimal/off), CALayer-based compositing
2. **Reader Mode** — minimal floating pane, dimmed background, paused animations, drag-aside workflow, console focus on dismiss
3. **Skin Builder** — AI-assisted skin generation from reference images or text prompts, local image generation, preview/iterate loop, export to `.hsk`, competition mode ("now you make one")

## Inputs for `/strategy`

- **Problem:** AI terminals are visually boring. No terminal lets you express yourself creatively through its UI.
- **Audience:** Erik first. Eventually: nostalgic 40-50 year olds, creative developers, anyone who wants their tools to feel personal.
- **Constraints:** macOS only. Must not degrade terminal performance when skins are off. Skin builder should be removable. Local-first image generation with option to plug in external APIs.
- **Non-goals:** Monetization. Community skin sharing infrastructure (future). Cross-platform. Accessibility standards enforcement (Erik's building for himself).
- **Success metric:** Erik daily-drives a custom skin that makes him smile and shows it to other people.
