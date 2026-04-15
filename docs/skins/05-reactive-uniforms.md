# Reactive Uniforms — Agent-State Shader Extension for Holoscape

> **Status:** Design, draft 1 (#5928). Graduates the inline `§A.4` design from [`04-ghostty-investigation.md`](./04-ghostty-investigation.md) into a standalone specification.
> **Feeds:** scope doc #5887, and implementation card #5930 (port Ghostty's shader pipeline into Holoscape).
> **Reference checkout:** `~/projects/github-repos/ghostty` (shallow, read-only). Source citations in this doc all point there.

---

## 1. Purpose

Holoscape adopts Ghostty's shader architecture wholesale (GLSL → SPIR-V → MSL via glslang + spirv-cross, `shadertoy_prefix.glsl` as the UBO layout, `updateCustomShaderUniforms*` as the update model). See [`04-ghostty-investigation.md`](./04-ghostty-investigation.md) §E.1 for the committed pipeline decision and §A.9 for the full adopt/extend/skip matrix.

This document defines the **one place Holoscape diverges from Ghostty's shader surface**: a set of new uniforms appended to the Globals UBO that expose Holoscape-specific semantic events (agent state, command lifecycle, channel state, output events, notifications) to shader authors.

This extension is the real novelty of Holoscape's skin system. Everything else about the shader pipeline is Ghostty's work, used as-is.

## 2. Scope

**In scope**

- The list of new uniforms, their names, types, semantics, and valid ranges.
- How each uniform is populated (which renderer update path, which source thread, how the value is snapshotted safely).
- The compatibility contract with upstream Ghostty shaders.
- Worked shader examples that exercise each uniform category.
- An implementation checklist for card #5930.

**Out of scope**

- The shader pipeline itself (glslang / spirv-cross integration) — #5930 implementation.
- Non-shader chrome skinning (tab bar, input box, window chrome) — card #5929 / [`06-chrome-skinning.md`](./06-chrome-skinning.md).
- Bidirectional compatibility with Ghostty (dropped — see §7).
- The per-tab "last interaction" stale-tab badge, which *sounds* related but is a chrome-level feature on a completely different timescale — see card #5936 and the note in §9.

## 3. Design constraints

Three hard rules, in priority order:

1. **Append-only on the Globals UBO.** Existing Ghostty uniforms (`iTime`, `iCurrentCursor`, `iFocus`, `iPalette[256]`, etc.) keep their binding index, position, and name. Holoscape's additions are appended after `iSelectionBackgroundColor` in the Globals block at `binding = 1, std140`. **Rationale:** any existing Ghostty shader must run unmodified in Holoscape. This is the floor of §A.9.
2. **Thread-safe without blocking the render thread.** Holoscape's state (agent mode, command lifecycle, etc.) lives on threads other than the renderer. The renderer reads these values once per frame. It must never take a mutex that the producing thread also holds. Section 6 defines the atomic-snapshot strategy that makes this safe and cheap.
3. **Default-zero semantics preserved.** Any shader that does not read Holoscape's extension uniforms behaves identically under both Ghostty and Holoscape. Concretely: all extension uniforms have integer or float types where `0` / `0.0` means "idle / no event / no state." An agent-ignorant shader reads no extension uniforms and therefore has no observable difference.

## 4. Event categories

Five categories, chosen because each maps cleanly onto a piece of state Holoscape's UI layer already tracks internally.

| Category | What Holoscape already knows | Why a shader author cares |
|---|---|---|
| **Output events** | A new output chunk arrived on this channel | Pulse/ripple on new content, ambient "living terminal" feel |
| **Command lifecycle** | Command started, finished, exit code | Celebrate success, flash red on failure |
| **Agent state** | Agent is idle / thinking / tool-use / errored | **The main differentiator.** Ambient state the user feels without reading text |
| **Channel state** | Channel identity, foreground/background, unread count | Tint per-channel, dim inactive, badge unread |
| **Notifications** | A user-facing notification fired (info / warn / error) | One-shot visual alerts that don't need a text overlay |

The categories are deliberately small. Each one gives shader authors *one new knob* — either a transition to animate or a value to dim/tint by. Resist the temptation to expose every piece of internal state; the shader UBO layout is a long-term contract and every uniform is a support burden.

## 5. Uniform surface

Appended to `shadertoy_prefix.glsl`'s Globals block. Names are prefixed to avoid collision with Ghostty's existing uniforms and to make the origin obvious in shader source.

```glsl
// --- Holoscape extension: output events ---
uniform int   iOutputEventCount;        // monotonic counter; changes ⇒ new output
uniform float iTimeLastOutput;          // iTime stamp of most recent new-output event

// --- Holoscape extension: command lifecycle ---
uniform int   iCommandState;            // 0=idle, 1=running, 2=completed
uniform int   iPreviousCommandState;
uniform int   iLastCommandExitCode;     // meaningful only when iCommandState == 2
uniform float iTimeCommandStart;
uniform float iTimeCommandEnd;

// --- Holoscape extension: agent state (the differentiator) ---
uniform int   iAgentState;              // 0=idle, 1=thinking, 2=toolUse, 3=error
uniform int   iPreviousAgentState;
uniform float iTimeAgentStateChange;    // stamped on every transition (both directions)

// --- Holoscape extension: channel state ---
uniform int   iChannelId;               // stable hash of channel identity
uniform int   iChannelIsActive;         // 1 if foreground channel, else 0
uniform int   iChannelUnread;           // unread count, clamped to int range

// --- Holoscape extension: notifications ---
uniform int   iNotificationKind;        // 0=none, 1=info, 2=warn, 3=error
uniform float iTimeLastNotification;
```

**Type choices.**

- Counters, ids, enums, and booleans-as-ints use `int`. No `uint` — stay consistent with Ghostty's existing `iFrame` / `iCursorVisible` style.
- Timestamps use `float` and are in the same time base as `iTime` (seconds since renderer start). Shaders compute `(iTime - iTimeX)` to animate.
- No `vec4` colors or `sampler2D` additions in this pass. Every extension uniform is 4 bytes. Keeping the struct cheap matters because it is updated per frame.

**Layout footprint.** 15 new scalar uniforms × 4 bytes = 60 bytes appended to the Globals UBO. With `std140` padding this rounds up, but it's still well under any meaningful budget.

## 6. Update paths and atomic snapshot strategy

Ghostty splits custom-shader uniform updates into two functions (`generic.zig:2010` and `generic.zig:2102`). Holoscape mirrors the split exactly — same function names, same triggers, same gating.

**`updateCustomShaderUniformsFromState`** — called when terminal/channel/command state is dirty (the equivalent of Ghostty's `if (self.terminal_state.dirty == .false) return;` at `generic.zig:2015`). Runs zero or more times per frame, only when something changed. Populates the state-driven uniforms:

- `iChannelId`, `iChannelIsActive`, `iChannelUnread`
- `iCommandState`, `iPreviousCommandState`, `iLastCommandExitCode`, `iTimeCommandStart`, `iTimeCommandEnd`

**`updateCustomShaderUniformsForFrame`** — called exactly once per frame (the Ghostty equivalent of `generic.zig:2102`). Handles the fast-path uniforms that need the per-frame timestamp (`iTime`) to stamp transitions:

- `iAgentState`, `iPreviousAgentState`, `iTimeAgentStateChange`
- `iOutputEventCount`, `iTimeLastOutput`
- `iNotificationKind`, `iTimeLastNotification`

### 6.1 Diff-and-stamp for transition uniforms

For every uniform pair `(iXState, iPreviousXState, iTimeXChange)`, the renderer runs the same block Ghostty uses at `generic.zig:2197-2207`:

```
let new_value = read_snapshot();      // lock-free, see §6.2
if new_value != uniforms.current {
    uniforms.previous = uniforms.current;
    uniforms.current  = new_value;
    uniforms.time_change = uniforms.time;   // iTime of this frame
}
```

**Every transition stamps.** Unlike Ghostty's focus-gain-only stamping at `generic.zig:2218` (which only stamps `iTimeFocus` when `self.focused == true`), Holoscape stamps in both directions. Rationale: shader authors can filter by checking `iAgentState` / `iPreviousAgentState` in the shader. Filtering at the source throws away data we can't reconstruct.

### 6.2 Lock-free snapshot from producer threads

Agent state, command state, output events, and notifications all live on threads *other than* the render thread. Per-frame, the renderer needs a safe, cheap read of each value without blocking the producer.

**Committed strategy: per-field `atomic<int>` / `atomic<float>`.** Each extension uniform is backed by a single atomic variable written from whichever thread owns the corresponding state, read by the render thread with a relaxed or acquire load (TBD at implementation time; acquire is the safe default). No mutexes. No futexes. No contention.

```swift
// Sketch (Swift/Obj-C++ interop TBD for #5930)
final class ReactiveUniformSnapshot {
    // NOTE: per-field atomics are intentional here. If we ever need
    // multiple fields to update consistently together (e.g. agent state
    // + start timestamp + command id in one observation), upgrade this
    // to a double-buffered snapshot struct. See 05-reactive-uniforms.md §6.2.
    let agentState = ManagedAtomic<Int32>(0)
    let agentStateChangeTime = ManagedAtomic<UInt32>(0)  // bit-cast from Float32
    let outputEventCount = ManagedAtomic<Int32>(0)
    // ... etc
}
```

**Why per-field, not a double buffer:**

- Every extension uniform is independent of the others in the sense that *no shader needs two of them to be consistent within the same frame*. A shader animating the agent-state transition doesn't also require the command-start timestamp to be from the same moment.
- Per-field atomics are ~4 bytes and one instruction to read. Double buffering adds indirection, a sequence counter, and the risk of a retry loop on the render thread.
- If we ever discover a shader authoring pattern that *does* need cross-field consistency, upgrading is a localized change — replace the individual atomics with a versioned snapshot struct. **Leave the comment shown above in the implementation site** so the upgrade path is discoverable.

### 6.3 Timestamp bit-casting

`iTimeAgentStateChange` and friends are `float` in the shader UBO but atomics in C++ / Swift typically prefer integer types. Bit-cast through `UInt32` on write and read. This is bit-exact and the cost is zero. Do not use `std::atomic<float>` on the producer side — it's fine on modern platforms but the bit-cast route is portable and auditable.

## 7. Compatibility contract

Holoscape's shader surface is a **superset** of Ghostty's. Every Ghostty shader runs unmodified. No Holoscape shader is required to run unmodified under Ghostty.

**What this means concretely:**

- **Binding layout:** Globals UBO stays at `binding = 1`, `std140`. Extension uniforms are appended *after* all Ghostty uniforms. Any shader that reads only Ghostty uniforms is byte-identical in its read behavior.
- **Prefix file:** Holoscape ships its own prefix at (TBD path for #5930) that starts with the verbatim Ghostty prefix and adds the extension block. Ghostty's upstream `shadertoy_prefix.glsl` is never patched in place — this matters when we rebase against upstream Ghostty changes.
- **Bidirectional compat: not required.** A Holoscape shader that reads `iAgentState` will not compile against the upstream Ghostty prefix. That's fine. Authors targeting both platforms use `#ifdef HOLOSCAPE` guards in their shaders (Holoscape's prefix defines `HOLOSCAPE`; Ghostty's doesn't).
- **No removals.** Ghostty can never remove a uniform from its prefix without breaking our layout. If upstream does this, Holoscape's prefix keeps the removed uniform as a deprecated stub (still declared, populated with the old value or zero) until we can migrate shaders.

## 8. Worked shader examples

One per category. Each composites on top of the terminal framebuffer read through `iChannel0`.

### 8.1 Agent state — red pulse on error, 0.6s fade

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float sinceError = iTime - iTimeAgentStateChange;
    float pulse = 0.0;
    if (iAgentState == 3 && sinceError < 0.6) {
        pulse = 1.0 - (sinceError / 0.6);
    }
    fragColor = vec4(mix(base.rgb, vec3(1.0, 0.1, 0.1), pulse * 0.5), base.a);
}
```

### 8.2 Agent state — soft blue glow while thinking

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float thinking = (iAgentState == 1) ? 1.0 : 0.0;
    // Slow breath, ~0.4 Hz
    float breath = 0.5 + 0.5 * sin(iTime * 2.5);
    vec3 tint = vec3(0.3, 0.6, 1.0) * thinking * breath * 0.15;
    fragColor = vec4(base.rgb + tint, base.a);
}
```

### 8.3 Command lifecycle — green flash on successful command

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float flash = 0.0;
    if (iCommandState == 2 && iLastCommandExitCode == 0) {
        float sinceEnd = iTime - iTimeCommandEnd;
        if (sinceEnd < 0.4) {
            flash = 1.0 - (sinceEnd / 0.4);
        }
    }
    fragColor = vec4(mix(base.rgb, vec3(0.2, 1.0, 0.3), flash * 0.3), base.a);
}
```

### 8.4 Output events — ripple on new output

Uses `iChannel0` sampling to warp the underlying terminal image radially from the cursor position whenever new output arrives.

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 cursor = iCurrentCursor.xy / iResolution.xy;
    float sinceOutput = iTime - iTimeLastOutput;
    float ring = 0.0;
    if (sinceOutput < 0.35) {
        float dist = distance(uv, cursor);
        float front = sinceOutput * 0.8;       // ring expansion speed
        ring = smoothstep(0.02, 0.0, abs(dist - front)) * (1.0 - sinceOutput / 0.35);
    }
    vec2 warped = uv + normalize(uv - cursor) * ring * 0.005;
    fragColor = texture(iChannel0, warped);
}
```

### 8.5 Channel state — dim when inactive

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float dim = (iChannelIsActive == 1) ? 1.0 : 0.6;
    fragColor = vec4(base.rgb * dim, base.a);
}
```

### 8.6 Notifications — single white flash on any notification

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
    float sinceNotif = iTime - iTimeLastNotification;
    float flash = 0.0;
    if (iNotificationKind > 0 && sinceNotif < 0.25) {
        flash = 1.0 - (sinceNotif / 0.25);
    }
    fragColor = vec4(base.rgb + vec3(flash * 0.15), base.a);
}
```

These examples together cover every extension uniform at least once. A first-pass "Holoscape reactive starter pack" of shaders would bundle all six as standalone `.glsl` files plus a combined version.

## 9. What this design is **not**

Two distinctions worth spelling out because they came up during the A.4 discussion:

- **Not a millisecond-independent UI feature.** The `iTime*` timestamps here are in the renderer's `iTime` base and are only meaningful on the ~1-30 second scale of visual transitions. Do not reuse them for "how long has the user ignored this tab" — that is a chrome-level, wall-clock feature with a minutes-to-hours timescale. Filed separately as card #5936.
- **Not a general event bus.** These uniforms expose a handful of carefully-chosen semantic states, not a firehose of internal events. If a shader author needs reactivity to something that isn't here, the right response is "should this category exist?" — not "append yet another uniform."

## 10. Implementation checklist for #5930

This section exists so that #5930 (port Ghostty's shader pipeline) has a crisp contract to build against.

- [ ] Ship Holoscape's own prefix file that starts with a verbatim copy of Ghostty's `shadertoy_prefix.glsl` and appends §5's extension block. Define `#define HOLOSCAPE 1` at the top of the prefix.
- [ ] Wire `shadertoy.zig`-equivalent pipeline: read `.glsl` → prepend prefix → glslang to SPIR-V → spirv-cross to MSL → Metal compile.
- [ ] Define `ReactiveUniformSnapshot` with one `ManagedAtomic` per extension uniform (Swift) or equivalent C++ `std::atomic` (see §6.2). Include the upgrade-to-double-buffer comment.
- [ ] Implement `updateCustomShaderUniformsFromState` (state-driven) and `updateCustomShaderUniformsForFrame` (per-frame) on the Holoscape renderer with the field assignments from §6.
- [ ] For each transition uniform, apply the diff-and-stamp pattern from §6.1. Stamp in both directions for every pair.
- [ ] Wire producer threads: channel model pushes to `iChannelId` / `iChannelIsActive` / `iChannelUnread`; command runner pushes to `iCommandState` / etc.; agent runtime pushes to `iAgentState`; output pipe pushes to `iOutputEventCount`; notification dispatcher pushes to `iNotificationKind`.
- [ ] Ship §8's six worked examples as the "reactive starter pack" under a `skins/examples/` directory.
- [ ] Verify the compatibility contract: pick one Ghostty shader from upstream and confirm it runs unmodified in Holoscape with zero code changes to the shader.
- [ ] Verify compile failures log-and-skip (never crash) per `04-ghostty-investigation.md` §A.7.

## 11. Open questions

None blocking this design. The three questions raised in `04-ghostty-investigation.md` §A.4 ("atomic snapshot strategy," "focus-asymmetry parity," "bidirectional compat") were all resolved during the second-pass review and are now committed in this doc (§6.2, §6.1, §7 respectively).

Future considerations worth flagging but not blocking:

- **Per-extension-uniform tween duration hints.** Right now shader authors pick their own fade durations (0.6s in §8.1, 0.4s in §8.3, etc.). We could expose a suggested duration per uniform as a const in the prefix. **Deferred** — let authors decide until we see a common pattern emerge.
- **Exposing agent identity.** `iAgentState` is a 4-value enum. We may want `iAgentKind` (Claude, Aider, etc.) eventually. **Deferred** — not needed for v1, and premature standardization on an enum would force us to bump the UBO layout later.

## 12. Revision log

- **2026-04-15** — draft 1 (#5928). Graduated from `04-ghostty-investigation.md` §A.4. Expanded with §6.2 atomic-snapshot code sketch, §7 compatibility contract, §8 six worked examples, §10 implementation checklist for #5930.
