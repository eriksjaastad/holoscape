# Ghostty Investigation — Architecture + Skinning Findings

> **Status:** Draft, second pass (#5890). Companion to `01-research-winamp-and-modern-equivalents.md`. Corrects §6 of that doc after reading Ghostty's source directly.
> **Reference checkout:** `~/projects/github-repos/ghostty` (shallow clone, read-only). All claims in this doc are cited to file + line.
> **Purpose:** Two questions. (1) How does Ghostty implement custom shaders behind a terminal — can we borrow the architecture? (2) What else in Ghostty is worth studying for Holoscape's general feature set?

---

## 0. TL;DR

- **Ghostty's shader system is more sophisticated than `01-research` claimed.** It already has a partial reactivity model (cursor, focus, colors, palette) and a built-in power/animation-mode knob. Holoscape's "Winamp 5 + reactivity" framing needs to be narrowed — the novelty is **agent-state reactivity**, not reactivity in general.
- **The entire Shadertoy ecosystem ports to Ghostty for free** because Ghostty's shader format *is* Shadertoy (GLSL `mainImage` + prefix). If Holoscape adopts the same prefix, it inherits the same library.
- **Architecture is Zig core + Swift/AppKit shell on macOS.** The terminal parser, renderer, and state machine live in `src/`. Only the window chrome, menu bar, settings UI, and SwiftUI integration live in `macos/`. `libghostty-vt` is an extractable C/Zig library covering the VT parser alone — potentially usable by us one day.
- **There are at least six Ghostty subsystems worth studying for general Holoscape features** (Command Palette, Global Keybinds, Quick Terminal, Splits, App Intents, AppleScript). Separate cards, separate bucket.
- **Pipeline decision is committed** (Part E.1): adopt Ghostty's GLSL → SPIR-V → MSL pipeline to inherit the Shadertoy ecosystem.

---

## Part A — Skinning Findings

### A.1 Ghostty's shader pipeline, end-to-end

User workflow:

1. Drop a `.glsl` file somewhere on disk.
2. Point `custom-shader` in config at its path (can be relative or absolute, optional or required).
3. Ghostty loads it on next config reload. Config reload is live — all open terminals pick up the new shader.

Pipeline inside the engine (`src/renderer/shadertoy.zig`, 427 lines):

```
.glsl file (Shadertoy-style mainImage)
    │
    ├── loadFromFile()
    ├── glslFromShader()      — prepend shadertoy_prefix.glsl (uniforms + mainImage wrapper)
    ├── spirvFromGlsl()       — compile via glslang to SPIR-V
    └── mslFromSpv()          — cross-compile via spirv-cross to MSL (Metal Shading Language)
           │
           └── Metal renderer compiles and runs at frame time
```

Two things jump out:

1. **Users write Shadertoy shaders, not Metal shaders.** `src/renderer/shaders/shadertoy_prefix.glsl` is **52 lines** and provides the Globals UBO, `iChannel0` sampler binding, and a `main()` that calls `mainImage(out fragColor, in fragCoord)`. That's the same entry point shadertoy.com uses. Any existing Shadertoy shader runs in Ghostty with zero modification.
2. **The pipeline is portable by design.** GLSL → SPIR-V → MSL means the same user shader also compiles to OpenGL on Linux. Holoscape is macOS-only and could skip the SPIR-V hop and ship Metal directly — simpler, one fewer dependency, but we lose the Shadertoy ecosystem. **Recommendation: do what Ghostty does.** The glslang + spirv-cross dependency is cheap and the payoff (thousands of existing shaders) is enormous. This recommendation is committed in Part E.1.

### A.2 The uniform block — Ghostty's reactivity surface

`shadertoy_prefix.glsl` declares one uniform block, bound at index 1, and one sampler2D at binding 0. Verbatim (relevant slice, lines 3–31):

```glsl
layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int   iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
};
layout(binding = 0) uniform sampler2D iChannel0;
```

Notes worth tracking for our own UBO design:

- **`iChannel0` is the terminal's own framebuffer.** That's the load-bearing bit. Shaders sample the already-rendered terminal, then composite. It's why the custom shader runs *after* the terminal, not *behind* it.
- **Color uniforms are `vec3`** (`iBackgroundColor`, `iForegroundColor`, `iPalette[256]`, etc.) but **cursor colors are `vec4`**. Matches the terminal palette model — cursor carries alpha for style effects.
- **`iChannelTime[4]` and `iChannelResolution[4]` are declared but unused** (Shadertoy ABI compatibility stubs).
- **Cursor style enum is defined inline** in the prefix (`CURSORSTYLE_BLOCK = 0` through `CURSORSTYLE_LOCK = 4`), so shaders can branch on cursor style.

### A.3 How the reactivity diff-and-stamp works

Ghostty's generic renderer (`src/renderer/generic.zig`, 3374 lines) updates custom-shader uniforms on **two separate paths**:

1. **`updateCustomShaderUniformsFromState`** at **`generic.zig:2010`** — runs only when `terminal_state.dirty != .false` (`:2015`). Handles 256-color palette, fg/bg, cursor color, cursor text, selection fg/bg, cursor visibility, cursor style. Cursor style uses the simple shift pattern: `previous = current; current = new`. This is the **state-driven path** — fires when the terminal itself tells the renderer something changed.
2. **`updateCustomShaderUniformsForFrame`** at **`generic.zig:2102`** — runs every frame. Handles cursor position and focus. This is the **per-frame path**.

The cursor position diff-and-stamp in the per-frame path is the template we'd copy for agent-state uniforms. Verbatim from `generic.zig:2197-2207`:

```zig
const cursor_changed: bool =
    !std.meta.eql(new_cursor, uniforms.current_cursor) or
    !std.meta.eql(cursor_color, uniforms.current_cursor_color);

if (cursor_changed) {
    uniforms.previous_cursor = uniforms.current_cursor;
    uniforms.previous_cursor_color = uniforms.current_cursor_color;
    uniforms.current_cursor = new_cursor;
    uniforms.current_cursor_color = cursor_color;
    uniforms.cursor_change_time = uniforms.time;
}
```

Focus stamping is at `generic.zig:2210-2221` and has a **quirk worth noting**: `iTimeFocus` is only stamped when `focused == true` (`:2218`). Losing focus does not stamp. This means shaders can animate "just got focused" but not "just lost focus." We may or may not want that asymmetry in Holoscape — flag it for the A.4 design.

Shaders animate transitions by reading `(iTime - iTimeCursorChange)` and tweening between `iPreviousCursor` and `iCurrentCursor`. Same pattern for focus via `iTimeFocus`. **Duration of the tween is the shader author's choice** — nothing in the engine constrains it.

This is **exactly the hook pattern we'd extend for agent state** (see A.4).

### A.4 Agent-state uniform extension — design

> **This section is now a summary. The full design lives in [`05-reactive-uniforms.md`](./05-reactive-uniforms.md).** Graduated 2026-04-15 via #5928.

The load-bearing contribution of this investigation is a set of new uniforms appended to Ghostty's Globals UBO that expose Holoscape-specific semantic events to shader authors. Five event categories:

- **Output events** — new output chunk arrived on this channel
- **Command lifecycle** — command started, finished, exit code
- **Agent state** — idle / thinking / tool-use / errored (the main differentiator)
- **Channel state** — channel id, foreground, unread count
- **Notifications** — info / warn / error one-shot events

The extension reuses Ghostty's diff-and-stamp pattern from `generic.zig:2197-2207` and its two-path update split (`updateCustomShaderUniformsFromState` at `:2010` vs. `updateCustomShaderUniformsForFrame` at `:2102`) verbatim. The UBO is append-only; every Ghostty shader runs unmodified under Holoscape.

Three design decisions locked in during second-pass review (2026-04-14) and carried forward into `05-reactive-uniforms.md`:

1. **Atomic snapshot strategy: per-field atomic int**, with an in-code comment flagging the upgrade path to a double-buffered snapshot if multi-field consistency ever becomes necessary.
2. **Every transition stamps**, in both directions. No focus-gain-only asymmetry like Ghostty's `generic.zig:2218`.
3. **No bidirectional Ghostty compat.** Holoscape shaders target Holoscape; `#ifdef HOLOSCAPE` guards are available for authors who want dual-target shaders.

See `05-reactive-uniforms.md` for the full uniform list, update-path assignment per field, atomic-snapshot code sketch, compatibility contract with upstream Ghostty, six worked shader examples (one per category), and the implementation checklist for card #5930.

**Not a shader concern but filed here so we don't lose it:** the millisecond-scale agent-state timestamps in the design above are purely for shader animation (0.3-1.0 second transitions). They are **not** the same thing as a per-tab "last user interaction" wall-clock timestamp for spotting forgotten channels. That is a separate chrome-level feature — see card #5936.

### A.5 Correcting §6 of the research doc

`01-research-winamp-and-modern-equivalents.md` §6 positioned Holoscape as:

> Ghostty shader model + Winamp 5 scene graph + reactivity driven by agent state.

After reading Ghostty's source, this is **partially wrong** in a load-bearing way:

- **Ghostty already has reactivity.** Not just `iTime`. Cursor position, cursor color, focus state, selection colors, full color palette are all live uniforms with previous/current pairs and change timestamps. Shaders can pulse on focus, tween on cursor move, react to theme changes — today.
- **So "reactivity" isn't the differentiator.** What Ghostty does *not* have is reactivity to **agent/terminal semantic events**: new output line, exit code of last command, "thinking" state, channel notifications. Those are Holoscape-only because they come from our custom layer above the terminal, not from the terminal itself. Section A.4 of this doc is the concrete design.
- **Winamp 5 scene graph is also not quite the right mental model.** Ghostty composes multiple shaders in order (`custom-shader` is a `RepeatablePath`) but it doesn't have a scene graph — no containers, layers, buttons, animated sprites. For a pure shader-behind-terminal effect, you don't need one.

**Corrected positioning:** Holoscape's skin system is **Ghostty's shader model, extended with a semantic-event uniform layer that exposes agent/terminal state**. The novel contribution is narrower than the research doc claimed, but still real. We should also decide (scope doc #5887) whether we want a Winamp-5-style *scene graph* on top of shaders for non-shader chrome (translucent input boxes, curved tab bars, animated overlays) — that's a second, separate decision.

Action: update `01-research-winamp-and-modern-equivalents.md` §6 with this correction in a follow-up PR. Don't let the stale framing propagate into the scope doc.

### A.6 Power / animation mode — already solved

Ghostty has `custom-shader-animation` at `src/config/Config.zig:3045` (default) and the enum at `:5222`. Three values:

- `true` (default) — render loop runs only when the terminal is **focused**. Saves CPU on unfocused splits.
- `false` — no animation loop. Render only when the terminal contents change.
- `always` — render loop runs continuously, focused or not. Explicitly noted as "more CPU per terminal surface."

This is exactly the battery story we'd need for #5887, and it's trivially adaptable. We might add a fourth mode: `on-battery-throttled` that drops to 30fps when unplugged. But the three-mode baseline is a proven starting point — don't reinvent.

### A.7 Shader loading mechanics (worth copying)

From `shadertoy.zig`:

- Config value is `RepeatablePath` — ordered list of paths.
- Paths can be marked `optional` (skip if missing, no error) or `required` (error if missing). Clever — lets shader packs ship with optional shaders.
- Shader file read limit: **4 MB**. Fine for any fragment shader.
- Compile errors are logged, not surfaced as config errors. Reason: "shader compilation happens after configuration loading on the dedicated render thread." This is a deliberate decoupling — config load must not block on GPU state.
- If a shader fails to compile, it's silently dropped. The terminal still runs. No crash.

**For Holoscape:** we should mirror this robustness. Skin compile failure = log + skip, never crash the terminal.

### A.8 What Ghostty has that we'd inherit

If we adopt the same prefix and compilation pipeline:

- **Every Shadertoy shader on shadertoy.com runs in Holoscape unmodified** — that's ~20,000 shaders.
- **Every Ghostty shader runs in Holoscape unmodified** — Ghostty has a growing community library.
- We get the cursor/focus/palette reactivity for free.
- We get multi-shader stacking for free.
- We get the animation mode semantics for free.

That's a *lot* of leverage from one architectural decision. The research doc already concluded feasibility was easy; now we know compatibility is cheap too.

### A.9 What Holoscape adopts vs. extends vs. skips

Decision matrix for each Ghostty skinning subsystem:

| Subsystem | Action | Notes |
|---|---|---|
| Shadertoy prefix (`shadertoy_prefix.glsl`) | **Adopt verbatim** | Binding indices, uniform names, UBO layout. Extend with appended fields only. |
| GLSL → SPIR-V → MSL pipeline | **Adopt** | glslang + spirv-cross. See Part E.1 for the committed decision. |
| Cursor/focus/palette uniforms | **Adopt** | Same names, same semantics, same diff-and-stamp. |
| Agent-state uniforms | **Extend** | Append to Globals UBO. See A.4. |
| State-driven + per-frame split update paths | **Adopt** | Same two functions, same triggers. |
| `custom-shader-animation` three-mode knob | **Adopt** | May add fourth `on-battery-throttled` mode. |
| `RepeatablePath` + `optional`/`required` config model | **Adopt** | Good pattern for shader packs. |
| Compile-failure = log + skip | **Adopt** | Non-negotiable robustness. |
| 4 MB shader file limit | **Adopt** | No reason to deviate. |
| Multi-shader ordered composition | **Adopt** | Zero cost, inherit the pattern. |
| Non-shader chrome skinning (input box, tabs, window) | **Extend** | Ghostty has nothing here. Design in `06-chrome-skinning.md`. |
| Reactive overlays (particles, animated glyphs above terminal) | **Extend** | `CAEmitterLayer` territory from research doc §2.3. |

Those three "Extend" items define the scope doc (#5887). **Ghostty compat is the floor; the three items above are the ceiling.**

---

## Part B — General Architecture Findings (Not Skin-Related)

These are for the *other* Kanban bucket — non-skinning features where Ghostty's approach is worth studying.

### B.1 Directory layout

```
ghostty/
├── src/                    Zig core — VT parser, terminal state, renderers
│   ├── renderer/           Metal.zig, OpenGL.zig, WebGL.zig, shadertoy.zig, shaders/
│   ├── config/             Config schema + hot reload
│   ├── apprt/gtk/          Linux GTK shell
│   └── ...
├── macos/Sources/
│   ├── Ghostty/            libghostty bindings, Surface View, config bridge
│   └── Features/           Per-feature SwiftUI modules (see B.4)
├── include/ghostty/vt/     C headers for libghostty-vt
└── example/                Minimal C/Zig usage of libghostty
```

**Architectural split we should note:** terminal correctness, rendering, and parsing live in the cross-platform core. Platform-specific UI (menu bars, windows, settings panels, menus, AppleScript, App Intents) lives in the Swift shell. Holoscape already has this split informally but less strictly. Worth examining whether our terminal logic is also cleanly separable.

### B.2 `libghostty-vt` — the parser as a library

Ghostty is factoring out its VT parser (ANSI/DEC escape sequences, cursor state, scrollback) as a standalone C/Zig library usable from any language including WebAssembly. It's stable and in production.

**Why this might matter to Holoscape:** we currently hand-roll terminal parsing. If `libghostty-vt` becomes a mature ecosystem dependency, we could trade "our parser" for "a battle-tested parser maintained by the Ghostty project" and focus all our engineering time on Holoscape's differentiators (skins, agent integration, UX). That's a long-term consideration, not a near-term card.

**Blocker:** API signatures are still in flux (no tagged version yet). Revisit when they hit 1.0.

### B.3 Multi-threaded terminal architecture

From the README: "Ghostty has a multi-threaded architecture with a dedicated read thread, write thread, and render thread **per terminal**." Our terminal likely runs on a single thread and only moves rendering off main. Worth an audit — we may be leaving perf on the table, especially when we start adding shader rendering. Note: this ties directly to A.4's open question about atomic snapshots for agent-state uniforms — if we adopt a per-terminal render thread, the snapshot boundary is well-defined.

### B.4 `macos/Sources/Features/` — module organization to study

Ghostty organizes per-feature Swift modules rather than grouping by layer. The list:

- `About`
- `App Intents`
- `AppleScript`
- `ClipboardConfirmation`
- `Command Palette`
- `Custom App Icon`
- `Global Keybinds`
- `QuickTerminal`
- `Secure Input`
- `Services`
- `Settings`
- `Splits`
- `Terminal`
- `Update`

Several of these map directly onto Holoscape Kanban cards:

- **Command Palette** — we don't have one. Clear win for the daily-driver experience. Ghostty's implementation is a standalone module we can read end-to-end.
- **Global Keybinds** — Holoscape's `New Channel hotkey` (#5862) is blocked on something Ghostty already solved.
- **App Intents / AppleScript** — Holoscape doesn't expose itself to Shortcuts or AppleScript. Ghostty does. If we want "tell Siri to open a new Holoscape channel in ~/projects" one day, this is the file to read first.
- **QuickTerminal** — Ghostty has a dropdown quake-style terminal. We don't. Possible future card.
- **Splits** — Ghostty has proper split panes. Our "New Channel UX" cluster could shortcut itself by reading how Ghostty handles splits.
- **Settings** — they have a full GUI settings panel. Holoscape has partial. Worth studying for the skins picker UI we'll eventually need.

### B.5 `macos/Sources/Ghostty/Surface View/` — how the terminal view embeds in AppKit

The Swift `SurfaceView_AppKit.swift` is **2267 lines**. That's the full surface view including `NSTextInputClient` conformance, drag and drop, scrollback scroll view, progress bar, drag handles, image support, and inspector. Holoscape's `HoloscapeTerminalView.swift` is much lighter. If we want IME support, drag targets, and proper text input handling, that file is the reference implementation.

One concrete win to lift: `NSTextInputClient` conformance. Holoscape currently doesn't implement the input client protocol properly, which is why CJK/IME input doesn't work (not that we've noticed yet, but it will bite us). Ghostty's implementation around line 1750 is the blueprint.

### B.6 Agent development docs

Ghostty ships an `AGENTS.md` that coding agents read on entry, and vetted prompts in `.agents/commands/`. Our equivalent is `CLAUDE.md` + `pt`-managed memory, which is fine, but the `.agents/commands` pattern for one-shot common tasks (e.g. `/gh-issue <number>`) is worth lifting. We already have skills — this is just another way to organize them.

---

## Part C — Proposed Cards (organized by bucket)

These are proposals, not created cards. Review and green-light individually.

### Bucket 1: Skinning implementation (directly feeds scope doc #5887)

1. **Port Ghostty's shader prefix + pipeline to Holoscape** — adopt `shadertoy_prefix.glsl` (with agent-state uniform extensions from A.4), wire up glslang + spirv-cross, first working custom shader behind the terminal view. Acceptance: one Shadertoy shader downloaded from shadertoy.com renders behind the terminal at 60fps, shader reload on config change works, shader compile failure logs and skips without crashing.
2. **Graduate A.4 design into `docs/skins/05-reactive-uniforms.md`** — pull A.4 of this doc into its own file after Erik review, refine uniform names, resolve open design questions (atomic snapshot, focus-asymmetry parity, default-zero semantics for bidirectional compat).
3. **Non-shader chrome skinning design** — the second layer: how does a skin author style the input box, tab bar, window chrome? This is the real Winamp 5 analog and the real novelty vs. Ghostty. Lives in `docs/skins/06-chrome-skinning.md`. Feeds scope doc.
4. **Update `01-research` §6 with the Ghostty correction** — small PR, rewrites the positioning claim.

### Bucket 2: General function implementation (non-skinning)

5. **Study Ghostty's Command Palette module** — read-only spike, produce a short doc on the pattern. Feeds a future "Holoscape command palette" card.
6. **Study Ghostty's Global Keybinds module** — read-only spike, feeds #5862 (New Channel hotkey).
7. **Study Ghostty's Splits module** — read-only spike, feeds the New Channel UX cluster.
8. **Study Ghostty's `NSTextInputClient` conformance** — read-only spike, potentially blocks a future "IME support" card.
9. **Audit Holoscape's terminal parser vs. `libghostty-vt`** — long-term decision: keep our parser or adopt theirs. Defer until `libghostty-vt` tags a version.
10. **Audit Holoscape's threading model** — are we leaving perf on the table by not running read/write/render on dedicated threads per channel? Find out before shaders land; ties to A.4 atomic-snapshot question.
11. **Per-tab "last interaction" timestamp + stale-tab badge.** Separate from A.4's shader-animation timestamps. Purpose: spot forgotten channels. UI: subtle badge/tint when a tab hasn't been interacted with in N minutes (N configurable; sensible default ~30-60 min). Lives in the tab bar, not the shader. Lightweight — just a `Date` per channel and a timer.

---

## Part D — Open Questions for Discussion

Trimmed after second pass — questions that had enough evidence to commit have moved to Part E.

1. **Scene graph or no scene graph?** For terminal backgrounds, shaders alone are enough. For input box / tab bar / chrome styling, we need something. Is that "something" a declarative skin manifest (like Winamp 5 XML) or imperative SwiftUI view modifiers gated on skin state? Scope doc territory (#5887). Do not decide here.
2. **Does the `libghostty-vt` long-term question change our current roadmap?** Probably not — it's a 2027 decision — but worth noting so we don't pile tech debt on our parser between now and then.

---

## Part E — Committed Decisions

### E.1 Shader pipeline: GLSL → SPIR-V → MSL (adopt Ghostty's pipeline)

**Decision:** Holoscape will compile user shaders via glslang (GLSL → SPIR-V) and spirv-cross (SPIR-V → MSL), matching Ghostty's pipeline and using the same `shadertoy_prefix.glsl` (with appended agent-state uniforms, see A.4).

**Rejected alternative:** Ship raw Metal shaders. Simpler (one fewer dependency, no SPIR-V hop), but loses the Shadertoy and Ghostty community ecosystems — ~20,000 shaders that would otherwise run unmodified. That's too much leverage to leave on the table for a one-library savings.

**Reasoning:**
- Inherits Shadertoy compatibility immediately (no translation layer).
- glslang + spirv-cross are both stable, well-maintained, and used by Ghostty in production on macOS — the integration risk is known-zero.
- Preserves the option of future Linux support without rewriting shaders.
- The dependency cost is one additional build-time toolchain, not runtime overhead (compilation happens once per shader load).

**Implementation note:** The compile step runs on Ghostty's render thread, not during config load (`shadertoy.zig`). We should follow the same split — never block config load on shader compilation.

---
