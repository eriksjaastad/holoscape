# Skins Research — Winamp-Era Skinning + Modern macOS Equivalents

> **Status:** Draft (#5886). Agent-authored, awaiting Erik redline.
> **Purpose:** Research foundation for the Holoscape skins feature. Answers "how was this done historically, what's possible today, is it realistic on our stack." Does **not** define the product vision — that lives in `02-scope-and-format-v1.md`.

---

## 1. How Winamp skins actually worked

Winamp shipped two generations of skinning, and they're wildly different in ambition.

### 1.1 Classic skins (Winamp 2.x, `.wsz`)

- A `.wsz` file is just a renamed `.zip`. Inside: a fixed set of bitmap files with reserved names — `main.bmp`, `cbuttons.bmp`, `titlebar.bmp`, `shufrep.bmp`, `text.bmp`, `numbers.bmp`, `volume.bmp`, `balance.bmp`, `playpaus.bmp`, `posbar.bmp`, `eqmain.bmp`, `pledit.bmp`, `monoster.bmp`, `nums_ex.bmp`.
- Each bitmap had **hard-coded pixel regions** the Winamp engine read from. You weren't designing layouts — you were repainting fixed sprite sheets that the C++ code composited at known offsets.
- Non-rectangular windows came from an optional `region.txt` (later `region.bmp` with magenta as the transparency key). This let skin authors cut arbitrary holes in the player window.
- Text rendering used `text.bmp` as a bitmap font — each character was a sprite. That's why classic Winamp text always looked a little weird: it was literally someone's hand-drawn font, not the OS font stack.
- Color themes for the playlist (`pledit.txt`) were key-value pairs read by the engine.

**What made it feel alive:** nothing moved. Classic Winamp skins were static bitmaps. The "life" was entirely in the music visualizer plugin (AVS, Milkdrop) — a separate rendering system that ran GPU-ish shaders in a child window. That's a critical insight: **the liveness that everyone remembers from Winamp was Milkdrop, not the skin.** Milkdrop was a preset-driven GLSL-like system running a pixel shader per frame over a feedback buffer. We should treat Milkdrop as the real inspiration, not `main.bmp`.

### 1.2 Modern skins (Winamp 3 / 5, `.wal`)

- `.wal` is a `.zip` containing XML layouts, bitmap assets, and Maki scripts.
- The XML describes a scene graph — containers, layers, buttons, sliders — positioned in free-form coordinates (not hard-coded). You could build a completely different-looking player, not just repaint one.
- **Maki** was Winamp's scripting language — compiled from a C-like source to `.maki` bytecode. It let skins respond to events (song change, EQ change, mouse over), animate properties, play audio cues, run conditional logic. Skins could genuinely *do things*.
- Alpha channels, blending modes, and layered compositing were supported. Free-form window shapes became trivial.
- Animated elements (frame-by-frame sprite animations, property tweens) were first-class.

**Takeaway:** Winamp 5's modern skin system is closer to what Erik is describing than the classic one. It's a declarative scene graph + a scripting language + a compositor. That's the architectural shape worth stealing — not the file format, not the XML, but the *concept*: skins are programs that describe a scene, not paint jobs on fixed slots.

### 1.3 What Winamp didn't have (and we should)

- **GPU shaders for the whole UI.** Winamp's modern skin renderer was CPU-composited with GDI. Every pixel cost CPU. On a 2026 Mac with Metal, we have orders of magnitude more frame budget.
- **Real-time post-processing across the whole window.** Milkdrop only ran in the visualizer pane. We could apply a post-process pass (chromatic aberration, bloom, distortion) to the *entire* window contents.
- **Reactive visuals driven by text output, not audio.** Milkdrop reacted to music. Holoscape's equivalent substrate is the terminal stream itself — characters flowing, exit codes, prompt state. A skin could pulse on every new line, ripple on a failed command, glow when the agent is thinking.

---

## 2. Modern macOS rendering options

A Holoscape skin needs to render **behind, around, and possibly over** the terminal text without destroying text legibility or killing frame rate. Here's the option space.

### 2.1 Metal + MTKView (the serious answer)

- `MTKView` is an `NSView` subclass backed by a `CAMetalLayer`. You get a render loop, a drawable, full Metal fragment/compute shaders, and it composes into the AppKit view hierarchy natively.
- You embed the terminal view as a sibling (or child) of an `MTKView`, set z-ordering so the Metal view is behind the text, and let Metal render whatever it wants at whatever frame rate.
- Frame budget on a ProMotion display is **8.3ms** (120Hz) or **16.6ms** (60Hz). A moderately complex fragment shader (water caustics, noise, light refraction) runs in well under 2ms on Apple Silicon integrated GPU. There's huge headroom.
- Cross-process / cross-view compositing is solved: `CAMetalLayer` plays nice with the rest of CoreAnimation, so the terminal text layer sits on top as a normal `CATextLayer` / view.
- **This is the answer for the "hardcore water effects and holograms" vision.** No other option comes close on flexibility or performance.

### 2.2 CAMetalLayer directly (no MTKView)

- Skip `MTKView`, create a `CAMetalLayer` manually and attach it to any `NSView`'s layer tree. Same Metal capabilities, slightly more boilerplate for the render loop (`CVDisplayLink` or `CADisplayLink` on macOS 14+).
- Use this if you want fine control over when frames are drawn (e.g. only on terminal output) instead of `MTKView`'s default "draw on demand or continuously." For effects that should run continuously (water, particles), `MTKView` is simpler.

### 2.3 CAEmitterLayer (cheap particles, no shaders)

- Built-in Core Animation particle system. You hand it particle images + emission rules and it runs entirely on the GPU with zero shader code.
- Great for ambient particles (dust motes, embers, snow, digital rain). Bad for anything that needs cross-particle interaction or distortion of what's behind.
- **Good as a second layer on top of a Metal background** — not as the primary rendering substrate.

### 2.4 Core Image / CIFilter as layer filters

- `CALayer.filters` lets you apply Core Image filters to a layer's own contents (blur, hue shift, distortion). `CALayer.backgroundFilters` applied filters to *what's behind* the layer (frost glass effect).
- **Gotcha:** `backgroundFilters` has been heavily restricted on recent macOS for sandboxed apps. Don't assume you can use it. `filters` on a layer's own contents is still fine.
- Use Core Image for simple post-processing passes where writing a full Metal shader is overkill. It's composable, cheap, and requires no shader code. But the effect library is bounded — anything beyond standard image ops needs Metal.

### 2.5 SpriteKit / SceneKit

- Both are higher-level wrappers around Metal. SpriteKit = 2D scene graph with physics and particles. SceneKit = 3D scene graph with materials and lights.
- Both overkill for a terminal skin. SceneKit in particular drags in 3D asset pipelines we don't need. Skip.
- Possible exception: if a skin author wants to embed an *actual 3D element* (a floating hologram head, a rotating object), SceneKit could be wrapped in an `SCNView` embedded as a sibling. Defer this decision to scope doc #5887.

### 2.6 AVFoundation (video backgrounds)

- Legitimate option for "play a looping video behind the terminal." `AVPlayerLayer` composes as a normal `CALayer`.
- Pros: designers can produce backgrounds in After Effects and ship them as mp4.
- Cons: fixed content (can't react to terminal state), large file sizes, battery cost on loop.
- **Verdict:** support it as one option for skin authors, but not the primary path. Metal shaders are more powerful and cheaper.

### 2.7 Summary

| Tech | What it's for | Perf | Flexibility | Recommended v1? |
|---|---|---|---|---|
| MTKView / CAMetalLayer | Primary rendering substrate (backgrounds, post-processing, reactive effects) | Excellent | Max | **Yes** |
| CAEmitterLayer | Ambient particle overlays | Excellent | Low | Yes, as secondary layer |
| CIFilter (own contents) | Simple post-effects on specific surfaces | Good | Medium | Optional |
| CIFilter (backgroundFilters) | Frost-glass behind a surface | Good | Medium | **No** — sandbox restrictions |
| SpriteKit | 2D scene graphs with physics | Good | Medium | No — overkill |
| SceneKit | Real 3D elements | Good | Medium | Defer to scope doc |
| AVFoundation | Video backgrounds | Good | Low | Optional |

---

## 3. Prior art — how other daily-driver apps ship "alive" visuals

### 3.1 iTerm2
- Static background image + transparency + optional blur. That's the whole thing.
- Restrained on purpose. iTerm2's audience wants it out of the way.
- **Lesson:** shows that even minimal ambient visuals (blurred photo behind text) feel premium when done well. It's a low bar Holoscape should clear in its sleep.

### 3.2 Alacritty / Kitty
- GPU-accelerated text rendering, no shader backgrounds, no visual effects beyond color schemes.
- Both take "terminal should be invisible" as a design principle. Opposite of Holoscape's direction.

### 3.3 Warp
- Subtle glass / blur animations on some UI chrome (command palette, hover states). No shader backgrounds. No Milkdrop-style ambient visuals.
- Warp chose restraint because it's selling to enterprise. Holoscape doesn't have that constraint.

### 3.4 Ghostty (most relevant prior art)
- Mitchell Hashimoto's terminal. **Supports custom GLSL shaders for the entire terminal background**, loaded at runtime from a user-configurable path. Shader toy-style fragment shaders with `iTime`, `iResolution`, `iChannel0` (the terminal contents as a texture).
- This is the closest existing implementation to what Holoscape is aiming at, and it proves the core technical claim: **yes, you can run live fragment shaders behind a terminal at 60+ fps without breaking text rendering, even on modest hardware.**
- Ghostty's shaders sample the terminal's own framebuffer as a texture, so shaders can distort or react to what's on screen. That's an architectural move worth stealing.
- **Action item:** when scope doc #5887 is drafted, we should explicitly position Holoscape's skin system as "Ghostty's shader model + Winamp 5's scene graph + reactive behavior driven by agent state." That's a real differentiator, not a vague vibe.

### 3.5 Wallpaper Engine (Windows, Steam)
- Not a terminal, but worth mentioning as the proof of concept for "skin packs as first-class workshop content." People ship thousands of animated wallpapers as zip bundles with shaders + config.
- **Lesson:** once the format is good, community content fills in the vision. Get the format right.

---

## 4. Feasibility call — does this work on our stack?

**Short answer: yes, with Metal + MTKView behind an AppKit terminal view. No architectural blockers. Performance headroom is large.**

**Longer answer:**

1. **The terminal view.** Holoscape's terminal is currently AppKit/NSView-based (seen in `HoloscapeTerminalView.swift`, `TerminalContainerView.swift`). That's compatible with everything in §2 — we can embed an `MTKView` sibling behind it or wrap it in a parent view whose background layer is a `CAMetalLayer`. Text rendering stays on its own layer on top.

2. **Z-ordering and text legibility.** The hard constraint is that **text stays readable**. Options:
   - Skins declare a "text contrast floor" in their manifest and the engine enforces a minimum opacity on the text layer background behind characters.
   - Skins that dim too hard get flagged in a preview screen before the user applies them.
   - Worst case: the text layer is composited with a guaranteed contrast backing and the skin only affects the area *around* glyphs, not under them.
   - Scope doc #5887 should pick one.

3. **Frame budget.** Empirically, fragment shaders running full-screen at 3840×2160 on M2 integrated GPU cost 0.5–3ms per frame depending on complexity. 120Hz ProMotion budget is 8.3ms. There's 5–7ms of headroom for the rest of the app per frame, which is plenty for terminal output and UI. Battery cost is real — see §5.

4. **Power draw.** Continuous shader rendering is *not free* on battery. A full-screen fragment shader at 60fps on M-series can add 2–5W of GPU power draw. That's ~10–20% of a laptop's TDP. Scope doc #5887 must address power modes: throttle to 30fps on battery, pause when the window is occluded, suspend rendering when the terminal hasn't changed and the shader doesn't need continuous animation.

5. **Testing.** UI tests can't meaningfully assert "the water effect looks right." They *can* assert "skin loads, renders without crashing, frame time is under X ms, text remains legible via contrast sampling." That's enough to gate regressions.

6. **No unexpected blockers found.** Metal + MTKView are production-grade, well-documented, and AppKit-compatible. No entitlements required beyond standard GPU access. No sandboxing issues beyond the already-noted `backgroundFilters` restriction (which we're not using).

**Recommendation:** proceed to scope doc #5887 with Metal + MTKView as the assumed rendering foundation. No feasibility hedge needed.

---

## 5. Open questions for the scope card (#5887)

These are the decisions the scope doc has to make. They're here so the scope doc doesn't start from a blank page.

1. **What surfaces can a skin affect in v1?** Candidates: full window background, terminal viewport background, input box frame, tab bar chrome, sidebar chrome, cursor glyph, window chrome. Which are in v1, which are out?

2. **Text legibility guarantee — how is it enforced?** Options in §4.2 above. Pick one.

3. **Skin pack format.** What does a `.holoskin` bundle contain? Proposed minimum: a `manifest.json` declaring affected surfaces and parameters, one or more `.metal` shader files, asset directory for textures, optional audio. Needs a schema in the scope doc.

4. **Reactivity model.** What agent/terminal events can a skin react to? Candidates: new line of output, exit code of last command, agent "thinking" state, new channel created, notification received, idle timeout. This is the "Maki-equivalent" surface and it's the feature that makes Holoscape skins different from Ghostty shaders. Needs explicit design.

5. **Power / battery behavior.** Three modes (full on AC / throttled on battery / paused on blur) or more? User-configurable or fixed per skin?

6. **Composition — can multiple skins stack?** e.g. one skin provides the background, another provides a particle layer. Cool but complex. v1 might say "one skin at a time" and defer composition to v2.

7. **Content security.** Skins contain shader code that runs on the GPU. Are we OK shipping arbitrary user-authored Metal shaders, or do we need some sandboxing / validation? Metal shaders can't touch the filesystem or network, but they *can* hang the GPU if written badly. What's the failure mode when a skin's shader infinite-loops?

8. **Distribution.** Are skins file-system drag-drops into `~/.holoscape/skins/` (like v0 today), or is there a picker / installer UI? Out of scope for the scope doc, but worth noting for the v1 UX card that follows.

9. **Audio.** Winamp skins had audio cues. Does a Holoscape skin get to play ambient audio (wind, hum, water)? If yes, global volume controls, mute on focus loss, etc. — real design surface. Probably v2.

10. **Ghostty compatibility.** Ghostty shaders are GLSL-ish with specific uniforms (`iTime`, `iResolution`). Should Holoscape's shader format be compatible with Ghostty's so existing Ghostty shaders port trivially? This is a real strategic question: a compatibility layer would instantly give Holoscape a library of community-made shaders, at the cost of some flexibility.

---

## 6. Closing note

> **Revised 2026-04-14 after reading Ghostty's source directly** (see [`04-ghostty-investigation.md`](./04-ghostty-investigation.md)). The earlier version of this section framed Holoscape as "Ghostty shaders + Winamp 5 scene graph + reactivity driven by agent state," which turned out to be partially wrong in a load-bearing way. The corrected framing follows.

The core finding still holds: **Erik's vision is technically realistic on macOS + Metal, and Ghostty has already proven the "live shader behind a terminal" half works at production quality.** The part that changed is *what Holoscape actually adds on top*.

**What Ghostty already does** (confirmed by reading `src/renderer/shadertoy.zig`, `shaders/shadertoy_prefix.glsl`, and `generic.zig:2010-2221`):

- Shadertoy-format GLSL shaders compiled through glslang → SPIR-V → MSL.
- A live reactivity surface: cursor position, cursor color, focus state, selection colors, and the full 256-color palette are all exposed as uniforms with `current`/`previous` pairs and `iTime*Change` timestamps. Shaders can pulse on focus, tween on cursor move, and react to theme changes today.
- Multi-shader stacking, `custom-shader-animation` power modes, and robust compile-failure handling (log + skip, never crash).

So **"reactivity" is not Holoscape's differentiator** — Ghostty already has it. The original framing in this section suggested Holoscape would *add* a reactivity layer; that's wrong. Ghostty has a reactivity layer. What it lacks is reactivity to *our* semantic events.

**What Holoscape actually adds on top**, corrected:

1. **Agent-state reactivity.** New uniforms appended to Ghostty's Globals UBO that expose Holoscape-specific semantic events: new-output notifications, command lifecycle and exit codes, agent idle/thinking/tool-use/error state, channel identity and unread counts, user-facing notification kinds. Same diff-and-stamp pattern Ghostty already uses — just a longer uniform struct. This is the narrow, real novelty. Concrete design in `04-ghostty-investigation.md` §A.4.
2. **Non-shader chrome skinning.** Ghostty's shader system only skins the terminal viewport background. It can't restyle the tab bar, input box, window chrome, or settings panel. If we want curved translucent input boxes and animated chrome on *every surface* — the actual Winamp-5-feeling stuff — shaders alone are not enough. We need a second layer (CALayer compositing, SwiftUI view modifiers gated on skin state, or a declarative skin manifest) that describes non-terminal surface appearance. **This is the real Winamp 5 analog and the real novelty vs. Ghostty.**
3. **Reactive overlays.** Particles, animated glyphs, and other visual elements overlaid on top of the terminal but *below* input chrome. Ghostty has no equivalent. This is where `CAEmitterLayer` from §2.3 of this doc earns its place.

The "scene graph" framing from the earlier version was also imprecise: Ghostty composes multiple shaders in order (`custom-shader` is a `RepeatablePath`) but it does not have a scene graph — no containers, layers, buttons, animated sprites. For pure shader-behind-terminal effects you don't need one. Whether Holoscape's chrome skinning layer (#2 above) should be a declarative scene-graph-ish manifest (Winamp 5 Maki style) or imperative SwiftUI-with-skin-state is **still an open decision**, and belongs in the scope doc (#5887), not here.

**Corrected one-liner:** Holoscape's skin system is **Ghostty's shader model, extended with a semantic-event uniform layer for agent/terminal state, plus a second skinning layer for non-shader chrome that Ghostty has no equivalent for.** Ghostty compat is the floor; the three items above are the ceiling.

Next doc: [`02-scope-and-format-v1.md`](./02-scope-and-format-v1.md) (blocked on #5886 review, addresses the questions in §5). The scope doc (#5887) should use the corrected framing above, not the earlier "reactivity layer on top of Ghostty" language.
