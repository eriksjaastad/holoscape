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
3. `BrokerBackedTerminalProcess` starts a per-session `BrokerOutputReadLane` on a serial background queue.
4. Native broker runtimes install an output-availability callback; PTY readability appends bytes and wakes that lane instead of relying on a blind 20 ms app-side polling timer. Runtimes that do not support availability callbacks keep the old short periodic fallback so out-of-process broker clients do not regress to one-second output latency.
5. The lane calls `coordinator.readAvailableOutput(...)` off the main actor when woken, with a slower heartbeat reserved for termination checks while otherwise idle.
6. The app hops back to the main actor only to feed returned bytes into SwiftTerm, run output handlers, and preserve termination/failure reporting.

This is asynchronous enough to avoid blocking the PTY producer most of the time, and broker output reads no longer run on the app main actor or spin at 20 ms when the native broker is idle. It is still not a Ghostty-style dedicated per-terminal read thread delivering directly into a terminal core: parsing/rendering remain SwiftTerm/AppKit work on the main actor.

### Terminal write path

For broker-backed sessions:

1. AppKit/SwiftTerm input reaches `HoloscapeTerminalView.send(...)` on the main actor.
2. `BrokerBackedTerminalProcess.send` enqueues bytes onto `BrokerInputWriteLane`, a per-terminal serial `DispatchQueue`.
3. The queue performs `coordinator.sendInput(...)` and the Unix-socket request off the main actor.
4. `NativePTYBrokerSessionRuntime.Session.writeInput` writes to the PTY master while holding the same per-session lock used for output-buffer mutation.
5. On success, the lane schedules a main-actor `pollOutputOnce()` for prompt echo/output refresh; on failure, it reports through the same terminal session-failure boundary as polling and resize failures.

This closes the largest typing-path risk identified by the first audit slice: slow broker transport or a blocked PTY write no longer holds AppKit input handling hostage. Holoscape still does not have Ghostty's dedicated per-terminal write thread, but it now has an ordered per-terminal write lane with explicit failure reporting and tests for non-blocking sends plus input ordering.

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
| PTY read | Dedicated read thread per terminal | FileHandle readability handler buffers bytes; native runtime wakes a per-terminal background read lane, then feeds SwiftTerm on main actor; non-signaling runtimes keep a short polling fallback | Lower: socket/runtime reads no longer contend with AppKit, idle native sessions do not spin, but parsing/rendering still do |
| PTY write | Dedicated write thread per terminal | Main-actor input enqueues to a per-terminal serial write lane; broker/PTY write happens off-main | Lower: typing path is no longer synchronously blocked by broker transport, but PTY lock contention still needs measurement |
| Render | Dedicated render thread per terminal | SwiftTerm/AppKit rendering fed on main actor; chrome/skin mostly main actor | Medium now, high once shader work is heavier |
| Terminal state ownership | Terminal core owns parser/state boundaries | SwiftTerm owns buffer; Holoscape wraps lifecycle and feeds bytes | Acceptable short-term; limits snapshot control |
| Agent/channel state | Needs thread-safe snapshots for renderer uniforms | Controller-derived main-actor state; no renderer snapshot API yet | Medium before skin state integration |
| Session survival | Terminal process not owned by UI lifecycle | Broker seam exists; Unix-socket host can outlive one request; socket handlers are bounded-concurrent | Good direction, but not a complete high-throughput terminal scheduler |

## Findings

### 1. The broker seam is the right architectural direction

Holoscape has already made the important product-level split: terminal sessions can be broker-owned instead of view-owned. This aligns with the tank-backend roadmap and should be kept.

Do not revert to SwiftTerm-owned process lifecycle for convenience. Continue pushing process/session survival into the broker while keeping the UI as a client.

### 2. Output read buffering and broker draining are off-main, while SwiftTerm feed remains main-actor-bound

`FileHandle.readabilityHandler` prevents the child process from depending directly on the UI loop for every byte, and the per-session buffer gives Holoscape a safe handoff point. `NativePTYBrokerSessionRuntime` now exposes an output-availability callback, and `BrokerOutputReadLane` drains broker output on a per-terminal background queue only when the runtime wakes it (plus a slow termination heartbeat). It only hops back to the main actor for SwiftTerm feed, output handlers, and termination/failure semantics.

This is a safer incremental step toward Ghostty's read split, but it is still weaker than Ghostty's per-terminal read/render pipeline under heavy output, many active tabs, or GPU skin load because terminal parsing/rendering remain main-actor/AppKit work.

### 3. Input writes now have a per-terminal async lane

User input no longer crosses the broker synchronously from the main actor. `BrokerBackedTerminalProcess` enqueues input onto `BrokerInputWriteLane`, preserving per-session order while moving socket/PTY writes off AppKit's input path.

This is the right incremental move toward Ghostty's dedicated write thread without rewriting SwiftTerm ownership. The remaining risk is lower-level contention: broker transport and `NativePTYBrokerSessionRuntime.Session` still serialize PTY writes with output-buffer mutation under the per-session lock.

### 4. The broker host is bounded-concurrent at the connection boundary

`BrokerSessionHostUnixSocketServer.run` now keeps accepting connections while dispatching handlers onto a bounded global queue. That prevents one slow request from blocking accept of unrelated broker requests as completely as the original single-request loop.

This is still not a per-terminal thread split. It is a concurrent request boundary protecting a runtime that still relies on global and per-session locks.

### 5. Per-session locking is conservative but coarse

`NativePTYBrokerSessionRuntime.Session` uses one `NSLock` for output buffer mutation, scrollback tail, termination status, and PTY writes. It is safe, but it also couples reads, writes, and status updates that Ghostty separates.

This should not be split prematurely, but future high-output tests should measure whether output append and input write contend.

### 6. Render and agent-state snapshots need a real boundary before skin-state integration

Right now agent/channel state is main-actor controller state. That is safe for UI, but it is not a renderer-safe snapshot contract. The upcoming channel-state-to-skin work should not let shader/chrome rendering reach into controllers directly.

The correct seam is a small immutable `ChannelRenderSnapshot` / `TerminalRenderSnapshot` built on the main actor and consumed by skin/render code. If a render thread arrives later, the same snapshot can cross that boundary.

## Recommendation

Do not try to clone Ghostty's thread model immediately. Holoscape is still using SwiftTerm for the terminal surface, and replacing that with a full per-terminal parser/render scheduler would be a large rewrite.

Do harden toward Ghostty's shape in the remaining incremental steps:

1. **Keep measuring broker-backed throughput under output pressure.** The executable baseline now covers both a small output/input case and a scaled many-session case; expand it further before making lower-level lock/runtime changes.
2. **Continue reducing read-path dependence on main-actor work.** Native broker output reads are now off-main and output-signaled; parsing/rendering still depend on SwiftTerm/AppKit on the main actor.
3. **Define immutable render/state snapshots before shader-state coupling.** Skins and shader uniforms should read snapshots, not live controller or SwiftTerm internals.

## Acceptance impact for roadmap

- #7168 session survival can continue on the current broker architecture.
- #7169 persistent channel state should define a snapshot boundary explicitly.
- #7175 skin-state integration should be blocked on snapshots, not on a full Ghostty-style renderer rewrite.
- A future performance card should stress-test heavy output plus typing across multiple broker-backed tabs and measure main-thread stalls.

## Proposed follow-up cards

1. **Scale broker-backed terminal throughput/stall benchmarks.** Initial scaled coverage exists for eight output-heavy sessions plus active input probes; keep expanding it when lower-level lock/runtime changes are proposed.
2. **Extend output availability signaling across the out-of-process broker protocol.** Native in-process broker output is signaled now; socket/process-host clients still need a protocol-level wake/stream mechanism before the polling fallback can be removed entirely.
3. **Tighten per-session runtime locking if scaled benchmarks show contention.** Split output append/drain from PTY writes only with benchmark evidence.
4. **Define terminal/channel render snapshots.** Freeze the state consumed by skins, shader uniforms, and tab truth so future render-thread work has a clean data boundary.
