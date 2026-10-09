# Session Survival Substrate Decision

Status: decision draft for #7167.

## Decision

Use a Holoscape-owned native session broker as the long-term core substrate. Do not make `tmux`, `dtach`, `abduco`, Project Tracker, or any external orchestrator a core dependency.

The broker can be packaged and launched by Holoscape, but it should be process-separated from the UI so terminal sessions can survive UI quit/relaunch and, later, UI crash. Project Tracker and other external systems may integrate through plugins after the core session model exists.

## Why this is the right shape

Holoscape is supposed to be self-contained and public-downloadable. A public user should be able to install Holoscape and get durable local terminal sessions without also installing a separate terminal multiplexer or the user's Project Tracker stack.

The current implementation launches processes directly through SwiftTerm's `LocalProcessTerminalView.startProcess(...)` in each channel controller. That is simple and good for the current app, but the child process lifecycle is tied to the UI process/view object. If the app exits or crashes, the session is not a durable object Holoscape can reattach to.

Evidence in current code:

- `ShellChannelController.activate()` creates a `HoloscapeTerminalView` and calls `terminalView.startProcess(...)`.
- `AgentChannelController.activate()` does the same for Claude/Codex-style agent commands.
- `SSHChannelController` also starts `/usr/bin/ssh` through a terminal process abstraction.
- `ChannelManager.saveState()` persists channel metadata such as type, label, working directory, host, command, endpoint, and pinned timestamp.
- `ChannelManager.restoreState()` recreates channel controllers from metadata, but this is respawn/restore shape, not reattach-to-existing-process shape.
- `ChannelState` is currently only `active`, `disconnected`, and `connecting`; it cannot represent survived, detached, stale, crashed, or reattach-failed states.

SwiftTerm can still be the renderer/parser. Its `LocalProcessTerminalView` feeds data into the terminal with `feed(byteArray:)`, and its lower-level APIs show the process boundary is separable in principle. The change is not "replace SwiftTerm"; it is "stop letting the SwiftTerm view own the durable process lifecycle."

## Options considered

### Option A — Keep current SwiftTerm local-process ownership

Pros:

- Already works.
- Minimal code.
- Best short-term velocity.

Cons:

- UI process owns child process lifetime.
- App quit/crash kills or abandons sessions.
- No durable session ID independent of channel UUID/view.
- Does not meet the tank-backend goal.

Verdict: keep only as compatibility/fallback while the broker is built.

### Option B — Run `tmux` as the core substrate

Pros:

- Proven process survival.
- Reattach semantics are mature.
- Good emergency/debug fallback.
- Sauron proved that tmux is a useful lesson source.

Cons:

- Makes Holoscape behavior depend on an external tool.
- Nested terminal semantics, scrollback, keybindings, shell integration, and status handling get more complicated.
- Public users inherit tmux setup/config expectations.
- Holoscape would be wrapping another terminal session model instead of owning its own.

Verdict: useful as an optional adapter or migration fallback, not the core product substrate.

### Option C — Use `dtach` or `abduco`

Pros:

- Lighter than tmux.
- Closer to pure detachment/reattach.

Cons:

- Still external dependencies.
- Less standard on macOS.
- Does not solve scrollback/state/history by itself.
- Adds another thing a public user may not have.

Verdict: not appropriate for core. Could be investigated only if the native broker hits a hard wall.

### Option D — Holoscape native session broker

Pros:

- Self-contained Holoscape-owned lifecycle.
- Broker survives UI quit/relaunch.
- Stable session IDs can outlive window/tab/view objects.
- Clean plugin boundary: Project Tracker can observe sessions later without owning them.
- Enables proper scrollback/history ownership and persistent tab truth.

Cons:

- More engineering work.
- Requires IPC protocol, lifecycle rules, persistence rules, and failure-mode tests.
- Must handle PTY resize, input backpressure, process termination, and reattach correctness carefully.

Verdict: recommended core architecture.

## Target architecture

### Components

1. **Holoscape UI app**
   - owns windows, skins, tab/sidebar UI, keyboard input, and rendering;
   - does not own durable child process lifetime;
   - attaches/detaches from broker sessions.

2. **Holoscape session broker**
   - launches and owns PTY-backed child processes;
   - assigns stable session IDs;
   - records session metadata and process status;
   - exposes input/output/resize/terminate/reattach operations over local IPC;
   - keeps a bounded scrollback/event buffer per session.

3. **Session registry**
   - persistent local record under Holoscape config/data storage;
   - maps session ID → command, cwd, env profile name, channel type, created time, last attached UI channel, last known status;
   - explicitly avoids storing secrets in raw env dumps.

4. **Plugin observers**
   - later optional layer;
   - Project Tracker plugin may receive session events, but the broker must run without it.

### Required broker API shape

Minimum operations for #7168:

- create session: command, args, cwd, env profile reference, terminal size;
- list sessions: stable IDs and lifecycle status;
- attach session: stream current scrollback tail plus live output;
- send input: bytes to PTY;
- resize session: rows/cols/pixel size;
- terminate session: graceful then forced cleanup;
- detach UI: keep process alive unless explicitly configured otherwise;
- reap exited sessions: preserve exit status and scrollback tail.

### Required lifecycle states

The current `ChannelState` is too small. The broker work should introduce a richer internal lifecycle model before UI styling:

- creating;
- running;
- detached;
- reattaching;
- exited;
- errored;
- stale;
- terminating.

Tab/UI state in #7169 can then map lifecycle + agent status into user-visible states like running, ready, needs approval, error, and stale.

## Implementation sequence

1. **Adapter seam first**
   - Introduce a terminal session protocol that channel controllers depend on instead of directly depending on `LocalProcessTerminalView.startProcess(...)`.
   - Keep the existing SwiftTerm local-process implementation behind that protocol so behavior stays green.

2. **Headless/broker prototype**
   - Build a broker service that can launch one local shell session and stream PTY bytes to an attached terminal renderer.
   - Verify input, output, resize, and process termination.

3. **Durable session registry**
   - Persist broker session records separately from UI channel metadata.
   - Store only safe metadata; never raw secrets.

4. **UI quit/relaunch survival**
   - Quitting the UI detaches from broker sessions.
   - Relaunch lists sessions and reattaches views.

5. **Crash/sleep hardening**
   - Simulate UI crash and relaunch.
   - Test laptop sleep/wake behavior.
   - Add stale-session detection and explicit recovery.

6. **Agent and SSH coverage**
   - Add agent command sessions after local shell works.
   - Treat SSH initially as a normal PTY command owned by the broker.

## Acceptance gates for #7168

Holoscape cannot claim process/session survival until these pass:

- Start shell session, run a long process, quit UI, relaunch UI, session is still running and attachable.
- Start agent command session, quit UI, relaunch UI, session is still represented with correct cwd/label/status.
- Kill UI process without graceful termination, relaunch UI, broker/session status is explicit and recoverable.
- Resize attached terminal; broker updates PTY size.
- Send input after reattach; output appears in the same session.
- Exited sessions preserve exit code and recent scrollback.
- Missing broker fails loudly with restart instructions; no silent degraded mode.

## Non-goals

- Do not implement Project Tracker ledger/sync/addressing in the core session broker.
- Do not make tmux required for normal Holoscape operation.
- Do not change the skin system to prove session survival.
- Do not solve all terminal correctness issues here; #7166 owns the terminal correctness audit.

## Near-term next step

Start #7168 by creating the adapter seam around local terminal process ownership, with tests proving existing channel activation still uses the current SwiftTerm path. Then add the broker behind the same seam incrementally.
