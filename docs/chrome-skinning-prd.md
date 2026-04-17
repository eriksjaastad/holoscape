# PRD: Chrome Skinning System

## Project Overview

AI terminals are visually boring — ChatGPT, Claude Code, Warp, iTerm all ship functionally identical dark rectangles. Holoscape's entire product thesis is that a terminal can be fun, expressive, and personal. Chrome skinning is the core differentiator: a Winamp-inspired system that transforms the window chrome (sidebar, borders, tab indicators, status areas) with custom visual assets — static textures, animated effects, and AI-generated designs. The terminal content stays functional; everything around it becomes a canvas for creative expression. "The Crisis of terminals."

**Audience:** Erik first. Eventually: nostalgic developers who remember Winamp, creative developers who want their tools to feel personal.

**Prior art in this repo:**
- `docs/skins/06-chrome-skinning.md` — detailed design doc with 23 surfaces cataloged, surface descriptor model, ninepatch system, state reactivity, hot reload, and a worked example manifest. This is the technical foundation.
- `docs/skins/09-chrome-skinning-discovery.md` — discovery brief from the conversation that surfaced collapsible regions, density modes, reader mode, and the AI skin builder.
- Existing `SkinEngine` + `SkinDefinition` in codebase — shallow v1 that loads `skin.json` from `~/.holoscape/skins/<name>/` but only applies colors, not images or chrome surfaces.
- Shader pipeline (cards 1-6, PRs #76-#89) — Metal rendering, GLSL compilation, per-frame compositing already built. Chrome skinning is a separate layer that composes alongside shaders, not a replacement.

## Goals

1. **Erik daily-drives a custom skin that makes him smile.** The terminal looks like it's from the future — or from a 50s car, or from Quake, or from a spaceship console. Whatever he wants.
2. **Any chrome region can be visually transformed.** The sidebar becomes glowing dots. The tab bar becomes riveted metal. The window border becomes carbon fiber. Every surface in `06-chrome-skinning.md` §6 is skinnable via the manifest.
3. **Skins adapt to screen size.** The same skin works on a laptop (compact, thin sidebar) and a big monitor (full blast, all four chrome regions active, animations running). No fixed pixel sizes.
4. **The terminal stays readable when needed.** Reader mode: a minimal floating pane over dimmed Holoscape for reading long outputs. Three skin density modes: full (animations, all regions), minimal (thin borders, no animations), off (bare terminal).
5. **AI can build skins.** Given a reference image or text description, an AI-assisted builder generates the skin assets, assembles the `.hsk` package, and preview-tests the result. Built as a native module inside Holoscape, designed to be pluggable/removable.

## Non-Goals

- **Monetization.** Free forever. No skin marketplace, no paid skins, no IAP.
- **Community skin sharing infrastructure.** Future work. No upload/download/rating system in this scope.
- **Cross-platform.** macOS only. No Windows/Linux skin compat.
- **Accessibility standards enforcement.** Erik is building for himself. Skins may have low contrast, tiny fonts, wild colors. Reader mode is the accessibility escape hatch.
- **Custom scripting language.** No MAKI equivalent. Animations and reactivity are declarative JSON (the manifest from `06-chrome-skinning.md` §7), not compiled bytecode. GLSL shaders handle anything that needs per-frame computation.
- **Non-rectangular window shapes.** Winamp used `region.txt` polygons for irregular windows. Holoscape stays rectangular. Chrome can visually suggest non-rectangular shapes via corner masks and transparency, but the window itself remains a standard NSWindow.

## Constraints

- **Security:** Skins are JSON manifests + image assets in a ZIP. No executable code. No network fetches from skin assets. Paths resolved relative to skin directory only — no `..` traversal, no absolute paths, no HTTP URLs. Skins must be safe to download without code review.
- **Tech Stack:** Swift, AppKit, CALayer for chrome compositing. Metal for shader layer (already built). 9-slice scaling via CALayer `contentsCenter`. Local image generation via Stable Diffusion on Apple Silicon (for skin builder).
- **Performance:** When `customShaderPath` is nil and no skin is loaded, Holoscape must perform identically to the current build. Zero overhead from unused features. When a skin is active, chrome redraws are event-driven (state transitions), not per-frame. Animations use CADisplayLink only during active transitions, then stop.
- **Backward compatibility:** Existing `SkinDefinition v1` files (`skin.json` with 10 color fields) must continue to load and render correctly. The v2 manifest adds an optional `surfaces` dictionary alongside v1 fields.

## Integration Context

- **Existing infra from `06-chrome-skinning.md`:**
  - `SkinEngine.swift` — loads skins from `~/.holoscape/skins/<name>/`. Extend, don't replace.
  - `SkinDefinition.swift` — v1 Codable struct. Add v2 `surfaces` dictionary as optional field.
  - `AppearanceConfig` — runtime appearance state. Already has `customShaderPath` (shader pipeline) and `skinName` (v1 skins).
  - `ColorTheme.swift` — 6 built-in themes. Skins can override theme colors.
  - 23 chrome surfaces cataloged with their source view files and hardcoded color call sites.
  - `ReactiveUniformSnapshot` — shared state source for both shader and chrome reactivity (designed in `05-reactive-uniforms.md` §6.2, not yet implemented).

- **Shader pipeline integration:** Chrome and shaders are independent layers that don't overlap. Chrome draws outside the terminal viewport via AppKit/CALayer. Shaders draw inside the terminal viewport via Metal. A skin can include both chrome PNGs AND a terminal shader — they compose cleanly (see `06-chrome-skinning.md` §11).

- **Skin file format (`.hsk`):** A renamed ZIP containing `skin.json` (v2 manifest), `assets/` (PNGs, ninepatch sidecars, fonts), and optionally `shaders/` (GLSL files for the terminal shader layer).

- **Collapsible regions:** Four independent chrome regions (top, right, bottom, left). Each region is independently collapsible. The skin manifest declares which regions it provides assets for. Missing regions = bare terminal on that side. Region collapse/expand is a runtime toggle, not a skin property.

- **Density modes:** Three runtime modes that control how much of the skin is active:
  - **Full:** All regions visible, animations running, maximum visual impact.
  - **Minimal:** Thin borders, no animations, reduced visual footprint for focused work on a laptop.
  - **Off:** Bare terminal, no skin rendering, zero overhead.

- **Reader Mode:** A separate floating NSPanel (not a skin feature, but designed to work with skins). When activated:
  - Holoscape dims (reduced alpha, color saturation, paused animations).
  - A minimal text pane appears with the recent terminal output, scrollable, draggable.
  - No navigation, no structure — just readable text.
  - User can drag it aside and continue interacting with the console (speech-to-text via Wispr Flow).
  - Dismissing the reader restores full skin glory.

- **Sidebar element customization:** Skin manifests can fully restyle sidebar tab indicators — not just colors/borders, but shapes (dots, squares, custom images). The sidebar is always scrollable regardless of indicator design. The manifest defines `sidebar.row.indicator` as a surface with its own fill/shape/animation.

- **Notifications:** `SkinDidChange` notification posted on hot reload. Chrome views observe and re-layout.

- **Publishing:** No external publishing. Skins live on disk at `~/.holoscape/skins/<name>/`.

## Success Metrics

- Erik daily-drives a custom skin for a week without switching back to bare terminal (except via reader mode for reading).
- The skin visually transforms at least the sidebar, tab bar, and window background — not just color changes, but image/texture-based chrome.
- Switching between full/minimal/off modes takes < 200ms with no visual glitch.
- Reader mode activates in < 100ms and correctly dims the skin underneath.
- At least one reference skin ("Holoscape Classic Winamp" from `06-chrome-skinning.md` §13) ships with the app as a built-in demo.
- The `.hsk` format is simple enough that a human can hand-build a skin by placing PNGs in a ZIP without any tooling.

## Open Questions for Kiro

1. **SkinContext injection pattern.** Every chrome view needs a reference to `SkinContext` to resolve its appearance. Should this be injected at view construction time (constructor injection via MainWindowController), or should views observe a shared `SkinContext` singleton? `06-chrome-skinning.md` §10.2 shows constructor injection. Kiro should spec the exact wiring.

2. **State transition animation coordination.** When agent state changes, should all surfaces animate simultaneously from the same timestamp (cohesive mood change) or independently with per-surface curves (more skin-author flexibility)? Flagged as open in `06-chrome-skinning.md` §16. Default to simultaneous; Kiro should decide if opt-in per-surface override is needed in v2.

3. **Collapsible region layout.** How do chrome regions collapse? Animated slide? Instant hide? Does the terminal viewport expand to fill the freed space, or does it stay fixed? What's the keyboard shortcut / UI gesture for region collapse?

4. **Reader Mode text source.** Where does the reader pane get its text? From the terminal's scrollback buffer directly? From the last N lines of output? From a specific command's output? How does it handle ANSI color codes — strip them or render them?

5. **Skin Builder architecture.** The discovery says "built-in, designed to be pluggable." Kiro should decide: is the builder a separate SwiftPM target that can be excluded from the build? A framework loaded at runtime? Or just a set of views behind a feature flag?

6. **AI image generation for skin builder.** What model? Stable Diffusion via Core ML? An external API? How are the generated images sliced into the correct skin regions? This may be a separate PRD if the scope is large enough.
