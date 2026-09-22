# Holoscape threading audit against Ghostty per-terminal split

Status: findings for card #5935.

## Scope

This is a read-only architecture audit of Holoscape's current terminal threading model against the Ghostty README claim captured in `docs/skins/04-ghostty-investigation.md` §B.3: Ghostty uses a dedicated read thread, write thread, and render thread per terminal.

The question is not whether Holoscape should copy Ghostty wholesale. The question is where Holoscape currently does terminal read, write, render, agent state, and UI input work, and which gaps matter before heavier shader rendering and durable session survival work.

## Current Holoscape model

### UI and channel state

- `ChannelManager`, `ShellChannelController`, and `AgentChannelController` are `@MainActor`.
- Channel lifecycle state (`connecting`, `active`, `stale`, `disconnected`), tab metadata, last interaction timestamps, persistent agent status, and recovery actions are updated on the main actor.
- SwiftTerm view mutation happens through `HoloscapeTerminalView`, also `@MainActor`.

Implication: tab truth is centralized and straightforward, but terminal output delivery and state refresh can contend with AppKit work if the main actor is busy.

### Terminal renderer / parser surface

Holoscape still uses SwiftTerm as the terminal surface:

- legacy/direct path: `HoloscapeTerminalView` subclasses `LocalProcessTerminalView`, letting SwiftTerm own process integration;
- broker-backed path: `BrokerBackedTerminalProcess` owns a `HoloscapeTerminalView` and feeds broker output into it with `terminalView.feed(byteArray:)`.

In both paths, the visible terminal buffer is mutated on the main actor. Holoscape does not currently have a separate per-terminal render thread equivalent to Ghostty's render thread.

### PTY/process ownership

Holoscape now has an explicit broker seam:

- app-side `BrokerBackedTerminalProcess` is `@MainActor` and polls broker output;
- `BrokerSessionCoordinator` is synchronous and owns durable metadata transitions;
- `BrokerSessionHostClientRuntime` sends one request per Unix-socket connection;
- `BrokerSessionHostUnixSocketServer` accepts one request at a time in its `run` loop;
- `NativePTYBrokerSessionRuntime` owns PTYs and child `Process` instances.

`NativePTYBrokerSessionRuntime` has one global runtime lock for the session dictionary plus a per-session lock around buffered output, scrollback, termination status, and writes to the PTY master.

### Terminal read path

For broker-backed sessions:

1. `NativePTYBrokerSessionRuntime.createSession` opens a PTY and assigns `masterHandle.readabilityHandler`.
2. The readability handler reads `availableData` and appends bytes into the session buffer under the per-session lock.
3. `BrokerBackedTerminalProcess` starts a main-run-loop `Timer` at 20 ms.
4. Each tick calls `coordinator.readAvailableOutput(...)` synchronously from the main actor.
5. The broker host returns buffered bytes; the app feeds them into SwiftTerm on the main actor.

This is asynchronous enough to avoid blocking the PTY producer most of the time, but it is not a Ghostty-style dedicated per-terminal read thread delivering directly into a terminal core. Output accumulation happens off the UI path; output draining/parsing/rendering is still app-main-actor-driven.

### Terminal write path

For broker-backed sessions:

1. AppKit/SwiftTerm input reaches `HoloscapeTerminalView.send(...)` on the main actor.
2. `BrokerBackedTerminalProcess` forwards bytes with `coordinator.sendInput(...)`.
3. The app performs a synchronous Unix-socket request to the broker.
4. `NativePTYBrokerSessionRuntime.Session.writeInput` writes to the PTY master while holding the same per-session lock used for output-buffer mutation.
5. `BrokerBackedTerminalProcess.send` immediately calls `pollOutputOnce()` after the write.

Holoscape does not currently have a dedicated per-terminal write thread or queue. Writes are serialized by the broker request path and session lock, but the initiating call is synchronous from the main actor. A slow broker transport or blocked PTY write can stall UI input handling.

### Render path

There are two render families:

- terminal text rendering is SwiftTerm/AppKit and main-actor-fed;
- skin/chrome rendering services (`SkinEngine`, chrome renderers, bake pipeline) are primarily `@MainActor`, with a few background or non-main pieces such as FSEvents callback queue and disk/image work.

Current shader work mirrors Ghostty's GLSL → SPIR-V → MSL direction, but Holoscape has not yet introduced a terminal-owned render thread. Shader compile/load must therefore be kept off config-load and must not block terminal output delivery.

### Agent state / persistent status

Agent status is tab/controller state, not terminal-core state:

- `AgentChannelController` refreshes persistent state from adapter state and terminal output detectors on output handler callbacks;
- terminal output state detection uses `terminal.lastLines(40)`, which reads SwiftTerm buffer text on the main actor;
- user input clears some output-derived persistent states.

This keeps state derivation simple, but it means agent-status sampling is downstream of main-actor terminal feed/render work. It is not yet an atomic snapshot boundary for a separate renderer.

## Comparison with Ghostty's split

| Concern | Ghostty target from audit input | Holoscape current state | Risk |
|---|---|---|---|
| PTY read | Dedicated read thread per terminal | FileHandle readability handler buffers bytes; app drains via main-actor timer | Medium: bursty output can lag behind UI/main-actor load |
| PTY write | Dedicated write thread per terminal | Main-actor input calls synchronous broker request and PTY write | Medium/high: slow broker or PTY write can make typing feel sticky |
| Render | Dedicated render thread per terminal | SwiftTerm/AppKit rendering fed on main actor; chrome/skin mostly main actor | Medium now, high once shader work is heavier |
| Terminal state ownership | Terminal core owns parser/state boundaries | SwiftTerm owns buffer; Holoscape wraps lifecycle and feeds bytes | Acceptable short-term; limits snapshot control |
| Agent/channel state | Needs thread-safe snapshots for renderer uniforms | Controller-derived main-actor state; no renderer snapshot API yet | Medium before skin state integration |
| Session survival | Terminal process not owned by UI lifecycle | Broker seam exists; Unix-socket host can outlive one request, but server loop is single-connection-at-a-time | Good direction, but not a complete high-throughput terminal scheduler |

## Findings

### 1. The broker seam is the right architectural direction

Holoscape has already made the important product-level split: terminal sessions can be broker-owned instead of view-owned. This aligns with the tank-backend roadmap and should be kept.

Do not revert to SwiftTerm-owned process lifecycle for convenience. Continue pushing process/session survival into the broker while keeping the UI as a client.

### 2. Output read buffering is off-main, but output consumption is main-actor-polling

`FileHandle.readabilityHandler` prevents the child process from depending directly on the UI loop for every byte, and the per-session buffer gives Holoscape a safe handoff point. But the terminal view only sees output when a main-actor timer polls the broker and feeds SwiftTerm.

This is probably fine for ordinary shell usage, but it is weaker than Ghostty's per-terminal read/render pipeline under heavy output, many active tabs, or GPU skin load.

### 3. Input writes are the biggest responsiveness risk

User input currently crosses the broker synchronously from the main actor. The Unix-socket client is one request per call, and `sendInput` can then trigger an immediate output poll. This is simple and testable, but it puts broker availability and write latency directly in the typing path.

Before Holoscape is used as the daily terminal for long agent sessions, input should move behind a per-session serial write queue or async actor boundary that preserves order without blocking AppKit input handling.

### 4. The broker host serializes all client requests today

`BrokerSessionHostUnixSocketServer.run` accepts one connection, handles it fully, then accepts the next. That keeps correctness easy, but it means one slow operation can block read/write/status requests for every session.

This is not a per-terminal thread split. It is a single broker request loop protecting a runtime with locks.

### 5. Per-session locking is conservative but coarse

`NativePTYBrokerSessionRuntime.Session` uses one `NSLock` for output buffer mutation, scrollback tail, termination status, and PTY writes. It is safe, but it also couples reads, writes, and status updates that Ghostty separates.

This should not be split prematurely, but future high-output tests should measure whether output append and input write contend.

### 6. Render and agent-state snapshots need a real boundary before skin-state integration

Right now agent/channel state is main-actor controller state. That is safe for UI, but it is not a renderer-safe snapshot contract. The upcoming channel-state-to-skin work should not let shader/chrome rendering reach into controllers directly.

The correct seam is a small immutable `ChannelRenderSnapshot` / `TerminalRenderSnapshot` built on the main actor and consumed by skin/render code. If a render thread arrives later, the same snapshot can cross that boundary.

## Recommendation

Do not try to clone Ghostty's thread model immediately. Holoscape is still using SwiftTerm for the terminal surface, and replacing that with a full per-terminal parser/render scheduler would be a large rewrite.

Do harden toward Ghostty's shape in three incremental steps:

1. **Introduce per-session async lanes in the broker client path.** Input writes and output reads should be ordered per session without synchronous main-actor socket calls in the keystroke path.
2. **Make the broker host concurrent at the connection boundary.** Accept connections continuously and handle each request on a bounded queue, while preserving per-session ordering for mutating operations.
3. **Define immutable render/state snapshots before shader-state coupling.** Skins and shader uniforms should read snapshots, not live controller or SwiftTerm internals.

## Acceptance impact for roadmap

- #7168 session survival can continue on the current broker architecture.
- #7169 persistent channel state should define a snapshot boundary explicitly.
- #7175 skin-state integration should be blocked on snapshots, not on a full Ghostty-style renderer rewrite.
- A future performance card should stress-test heavy output plus typing across multiple broker-backed tabs and measure main-thread stalls.

## Proposed follow-up cards

1. **Add broker-backed terminal throughput/stall benchmarks.** Exercise many sessions producing output while typing into one active tab; capture main-thread stall budget and output latency.
2. **Move broker input writes off the main actor.** Preserve per-session ordering and explicit failure reporting while avoiding synchronous socket work in the AppKit input path.
3. **Add concurrent broker request handling with per-session ordering.** Keep the runtime safe, but prevent one slow session request from blocking unrelated sessions.
4. **Define terminal/channel render snapshots.** Freeze the state consumed by skins, shader uniforms, and tab truth so future render-thread work has a clean data boundary.
