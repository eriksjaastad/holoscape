# HoloScape architecture decisions

This is the canonical short record of HoloScape's current architecture. `PRD.md`
defines product behavior, `SETUP.md` covers operator setup, and format-specific
documents define external file formats. Historical plans and audits are evidence,
not current requirements.

## Product boundary

HoloScape is a native macOS terminal. Its core promise is a reliable terminal
with clear channel identity, durable session truth, and persistent tab state.
It must start and remain useful without Project Tracker, MCP clients, message
ledgers, or any other external workflow system.

- App UI: AppKit.
- Terminal rendering: SwiftTerm.
- Local shell and agent process ownership: HoloScape's broker host.
- Remote SSH process ownership: the remote host; restore reconnects rather than
  pretending to preserve a remote PTY.
- Optional integrations: removable, permissioned plugins or separate helper
  executables.

Representative code: `AppDelegate`, `ChannelManager`, channel controllers,
`BrokerBackedTerminalProcess`, and `NativePTYBrokerSessionRuntime`.

## Session and process ownership

Local shell and agent PTYs belong to the broker host, not to an AppKit view or
tab. The GUI stores durable broker session identifiers and may detach and
reattach without killing a running child process.

1. The broker runtime owns PTY descriptors, child processes, process groups,
   buffered output, final drain, and termination authority.
2. The coordinator pairs runtime actions with durable registry transitions.
3. The app-side terminal bridge handles launch/reattach, replay, SwiftTerm byte
   delivery, input, resize, detach, retirement, and user-visible failures.
4. Closing presentation and terminating a process are separate operations.
5. App quit must retain cleanup authority until required detach/retirement work
   reaches a bounded truthful result.
6. A failed broker launch or reattach is visible. There is no silent in-process
   fallback that changes session-survival semantics.

The broker registry uses the richer lifecycle vocabulary `creating`, `running`,
`detached`, `reattaching`, `exiting`, `exited`, `terminating`, `errored`, and
`stale`. These broker-owned states are distinct from the six UI-facing tab
states below.

Source contracts:

- `Sources/Holoscape/Services/NativePTYBrokerSessionRuntime.swift`
- `Sources/Holoscape/Services/BrokerSessionCoordinator.swift`
- `Sources/Holoscape/Services/BrokerBackedTerminalProcess.swift`
- `Sources/Holoscape/Models/BrokerSessionRecord.swift`
- `docs/session-survival-phase1-audit.md`

Representative tests: `BrokerBackedTerminalProcessTests`,
`BrokerSessionCoordinatorTests`, `NativePTYBrokerSessionRuntimeTests`,
`ChannelManagerTests`, and `AppDelegateRestoredShellTests`.

## Durable lifecycle truth

The broker registry, not transient UI state, is authoritative for broker-owned
session lifecycle. Registry changes and irreversible runtime actions must
converge under failure and races; an operation failure may not become a
successful empty result.

Session identity is stable across request retries and app relaunch. Ambiguous
create outcomes must be resolved without launching duplicate or orphaned
processes. Final PTY bytes are drained before terminal exit becomes authoritative.

The broker protocol is typed and bounded. Production GUI-to-broker traffic uses
a local Unix socket with newline-delimited request and response frames, explicit
request deadlines, frame limits, and return-code/error propagation. A complete
newline is required before a frame is dispatched or decoded. Stdio remains a
diagnostic/test boundary, not a second production ownership model.

## Cross-process persistence and locking

The broker and GUI are separate processes. Any session persistence operation
available to both must use a cross-process authority. Swift actors, dispatch
queues, `NSLock`, and process-local singletons are insufficient on their own.

`PersistentFileOperationLocks` supplies deletion-stable per-session advisory
lock files. Registry and disk-backed scrollback maintenance preserve unrelated-
session parallelism while serializing conflicting operations for one session.
Lock, file, compaction, and cleanup failures are propagated rather than logged as
success.

Source contracts:

- `Sources/Holoscape/Services/PersistentFileOperationLocks.swift`
- `Sources/Holoscape/Services/BrokerSessionRegistry.swift`
- `Sources/Holoscape/Services/DiskBackedScrollbackStore.swift`

A real spawned-process lock regression is required for changes to this boundary.

## Scrollback and history

Broker scrollback and command/history metadata are different stores.

- Broker scrollback persists a bounded FIFO byte stream per broker session and
  replays a bounded tail when the app reattaches.
- Plain tail inspection is non-consuming.
- Transactional replay consumes one live unread generation only when replay
  contains that complete generation.
- Pending or failed persistence cannot permit premature consumption.
- Corrupt persisted scrollback is reported and skipped without falsifying a
  successful persistence result.
- Terminal output is not redacted. Secrets printed to the terminal may remain
  until retention evicts them.
- `HistoryBuffer` stores command/channel/settings/error history; it is not the
  source for broker replay.

The current retention and replay limits are documented in
`docs/scrollback-history-persistence.md`. Changes to those values or privacy
semantics require updating that contract and its tests together.

## Channel identity and persistent tab state

Presentation labels, launch identity, role/profile metadata, instance numbering,
broker identity, owner tokens, and persistent custom labels are separate fields.
A custom display label is an exact presentation value after input trimming; it
must not be consumed as launch identity or decorated with an instance suffix.

Persistent tab truth uses six distinct states: `disconnected`, `ready`,
`running`, `needsApproval`, `error`, and `stale`. `disconnected` means there is
no attached live process and a normal reconnect is available; `stale` means a
saved external session is missing or unverifiable. Display priority, from lowest
to highest, is disconnected → ready → running → needs approval → error → stale,
so lower-priority activity cannot hide a state that needs attention. Resolution
compares state-kind priority first, then source priority only to break a tie
(broker registry → process lifecycle → terminal output → agent adapter → user
action → plugin). Plugin attention states can therefore outrank lower-kind
runtime states and remain visible after process teardown; healthy/busy plugin
states are ignored while the channel is inactive. Owner tokens scope adapter
events to the process generation that owns the channel; stale or foreign events
cannot claim a fresh process.

Source contracts:

- `Sources/Holoscape/Models/PersistentChannelState.swift`
- `Sources/Holoscape/Models/AgentStatusAdapter.swift`
- `Sources/Holoscape/Protocols/ChannelController.swift`
- `Sources/Holoscape/Controllers/AgentChannelController.swift`
- `docs/agent-status-adapters.md`

Any label change must run the full channel matrix: every channel type, first and
numbered instances, renamed and unrenamed channels, save/restore,
duplicate/relaunch, and agent-identity indicators.

## App launch, restore, and quit

Launch recovery prepares broker state before restored tabs are published as
usable. User/API mutations and config saves cannot overwrite saved channels with
an empty or partial recovery snapshot. Restored broker work that can wait on a
socket runs off the main actor.

Quit coordinates channel persistence and broker detach/retirement. A denied or
deferred quit preserves notification mute state and does not discard cleanup
authority. Permanent failures must reach a bounded, observable outcome rather
than hanging forever or reporting success.

## Local API and MCP boundaries

The in-app HTTP API is trusted local automation bound to loopback, default port
`7865`. It is not a cloud service or session source of truth. Requests return
truthful HTTP failures when lifecycle state, validation, or routing rejects an
operation.

`HoloscapeMCP` is a separate executable that exposes MCP tools over the Swift MCP
SDK's newline-delimited stdio transport. Channel-control tools call the app's
loopback HTTP API. Its file, search, process, and AppleScript tools execute in the
MCP process with the invoking user's local privileges; they do not pass through
the app API. The executable therefore has a broader local trust surface than the
loopback API alone. It controls HoloScape; it is not the optional external-agent
MCP client channel. MCP smoke tests rebuild with
`swift build --product HoloscapeMCP`, write one JSON object plus a newline, and
read one JSON line per response.

The notification hook maps supported external events into channel state. Agent
events remain scoped by channel/process ownership as described in
`docs/agent-status-adapters.md`.

## Plugin boundary

Core terminal startup, PTY ownership, session recovery, tab truth, scrollback,
configuration, and setup diagnostics never depend on a plugin.

Plugins declare closed capabilities and permissions before side effects. Storage
is namespaced under plugin-owned paths. Plugin failures remain plugin-scoped and
must not block core startup or mutate broker/session truth. Project Tracker is
an optional first-party plugin and is never HoloScape core's source of truth.
There is no shipped marketplace or arbitrary dynamic-code loading contract.

Legacy group-chat and MCP-client controllers are still built-in optional channel
types. They must not become startup dependencies; new service-specific workflow
integration belongs behind the plugin seam rather than adding another core
dependency.

Current detail: `docs/plugin-architecture.md` and the manifest, manager, storage,
command-router, and Project Tracker plugin tests.

## Setup and permissions

HoloScape launches as a terminal before requesting broad macOS trust.
Notification authorization is lazy. Accessibility, Automation, Full Disk Access,
and network-volume access are requested or enabled only for workflows that need
them. `SETUP.md` and `docs/macos-permission-audit.md` are the operator contracts.

Failure semantics differ by owner:

| Failure | Required behavior |
| --- | --- |
| Malformed/unreadable app config | Preserve the file, use safe defaults where documented, report diagnostics |
| Missing or broken broker helper | Fail loudly; do not switch to weaker process ownership |
| Plugin startup/configuration | Report plugin-scoped diagnostics; keep core terminal available |
| Persisted session/scrollback corruption | Preserve actionable evidence, report it, and recover only where the contract permits |

## Visual and layout boundary

Skins, shaped windows, shaders, and vessel rendering are product capabilities,
not terminal ownership. Backend cleanup must not remove or materially redesign a
visual path without evidence that it is unused or broken. Headless tests assert
deterministic state; real display-link/window animation behavior belongs in
app-hosted smoke tests because macOS 26 headless AppKit teardown is unstable.

Split panes use the existing bounded flat layout model with at most four panes.
Layout persistence and restore are not wired in production yet. When implemented,
they must restore truthfully; documentation must not claim recursive layouts or
orientation persistence that the runtime does not implement.

External authoring contracts remain in `docs/amplify-format.md` and
`docs/chrome-format.md`. MercuryDeck art direction remains under
`Sources/Holoscape/Resources/Skins/MercuryDeck/`.

## Documentation authority

- `README.md`: build, run, test, and entry-point guide.
- `PRD.md`: current product behavior and explicitly future work.
- `DECISIONS.md`: current architecture and invariants.
- `SETUP.md`: operator setup, permissions, and recovery.
- `MIGRATIONS.md`: append-only bulk migration history.
- Format and adapter documents: external contracts named above.
- `docs/archive/` and `claude-specs/archive/`: historical evidence only; they
  must not drive new implementation.

When code changes one of these decisions, update the decision and executable
coverage in the same PR. Historical implementation plans should be archived,
not left beside current contracts as competing truth.
