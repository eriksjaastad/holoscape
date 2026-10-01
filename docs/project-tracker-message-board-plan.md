# Project Tracker Message Board Plan

## Purpose

Define the split for an agent-to-agent message board feature where Project Tracker owns the messaging system and Holoscape only surfaces it as a channel.

This plan also carves out a separate, smaller task for CLI/client detection so notification behavior can expand to `Claude`, `Clawed`, and `Codex` without blocking the larger message-board work.

## What We Know

- Holoscape previously had a manual agent-router prototype that routed `pt message` traffic into running tabs. It was retired after an October 2026 audit found no runtime usage and multiple message-loss paths. Do not use that sidecar as the foundation for this feature.
- Holoscape already has a chat-style channel type via `GroupChatChannelController`, so there is a UI pattern for rendering polled messages in a single tab.
- Project Tracker already has the real message primitive:
  - `pt message send`
  - `pt message list`
  - `recipient`
  - `reply_to`
- Project Tracker also has a separate `.claude/inbox` file-drop hook for task notifications. That is adjacent infrastructure, not the right source of truth for agent-to-agent messaging.

## Product Decision

The message board should be a Project Tracker feature first, not a Holoscape feature first.

Holoscape should not invent its own second message database, inbox model, or cross-computer sync logic. It should present a `Message Board` channel that reads from and writes to Project Tracker's message system.

## Ownership Split

### Project Tracker owns

- Message persistence
- Conversation model
- Cross-computer replication/sync
- Agent addressing
- Threading and reply semantics
- Human posting and replying interface in Auxesis/web UI
- API/CLI contract for reading and writing board messages
- Migration path away from ad hoc inbox/outbox usage

### Holoscape core owns

- The removable plugin contribution seam documented in `plugin-architecture.md`
- Core terminal operation when the Project Tracker plugin is absent, disabled, or unavailable
- Generic presentation primitives only when they are useful without Project Tracker

### First-party Project Tracker plugin owns

- An optional `Message Board` channel contribution
- Polling/rendering the PT-backed message feed inside the contributed channel
- Input for posting/replying into PT
- Optional plugin-owned unread badges, notifications, and deep links
- All Project Tracker endpoint configuration, availability state, and failures

## Architecture Direction

### Source of truth

Use Project Tracker `messages` as the canonical ledger.

Do not use:

- `~/.claude/inbox` as the canonical board
- `~/.claude/outbox` as the canonical board
- `~/.codex` internals as the canonical board
- a Holoscape-local SQLite store as the canonical board

### Cross-computer model

Project Tracker should handle cross-computer state. The optional first-party plugin should consume PT's API or CLI-visible contract; Holoscape core must not query PT.

If PT needs sync, that decision belongs there. Holoscape should not be responsible for Turso/libSQL/cr-sqlite policy.

### Inbox/outbox migration

Treat inbox/outbox as compatibility shims, not the future architecture.

Recommended end state:

- task notifications may continue to drop into `.claude/inbox` if useful
- agent-to-agent communication moves to `pt message`
- Holoscape `Message Board` becomes the normal human-visible surface
- any Claude/Codex adapters read/write the PT ledger instead of talking to each other through filesystem mailboxes

## Scope Proposal

### Phase 0: Small separate task

Upgrade client/CLI detection for Holoscape notifications so tabs recognize more than the current Claude-centric path.

Target clients:

- Claude
- Clawed
- Codex

This is intentionally separate from the message-board project.

### Phase 1: Project Tracker foundation

PT work:

- define the exact board semantics on top of `messages`
- decide whether board view includes all messages or a filtered subset
- decide whether routed agent-to-agent DMs appear on the board, or whether the board is only human-visible coordination
- add any missing fields needed for display and workflow
- expose a stable read/write interface that Holoscape can poll
- make Auxesis the primary web UI for posting and replying

Key PT decision:

- Is the board "all `pt message` traffic" or a dedicated board stream layered on the same table?

Current recommendation:

- keep one canonical `messages` ledger
- distinguish board-visible items with metadata, not a separate second system

### Phase 2: First-party Project Tracker plugin surface

Plugin work, using only the contribution points in `plugin-architecture.md`:

- contribute an optional `Message Board` channel entry that disappears when the plugin is disabled
- render PT messages in a single tab
- support posting a new message
- support reply to an existing message
- show sender, recipient, timestamp, reply target, and priority
- reuse generic chat presentation only through a plugin-facing seam; do not make `GroupChatChannelController` or any core channel controller depend on PT
- keep endpoint, polling, state, and failure handling plugin-owned so PT unavailability cannot affect core terminal readiness

### Phase 3: Agent integration

After PT and the plugin surface exist:

- agents can post into the same PT ledger through PT's supported contracts; the retired router sidecar is not revived
- human can watch an exchange from the `Message Board` tab
- human can intervene by replying in the board
- Claude/Codex adapters can be normalized around PT instead of per-tool inbox conventions

## Recommended PT Questions

These are the main questions to hand off to Project Tracker:

1. Should `pt message` become the official replacement for inbox/outbox-based agent messaging?
2. Should the board show all messages, only broadcasts, or only messages marked with board metadata?
3. Should direct routed agent-to-agent messages be visible to Erik by default in Auxesis and Holoscape?
4. Is reply threading shallow (`reply_to`) or do we need explicit conversation/thread ids?
5. What is the sync strategy for cross-computer delivery, and does PT already have a preferred replication path?
6. Does PT want one HTTP endpoint tailored for board rendering, or should Holoscape keep consuming the existing message list contract?

## Recommended Holoscape Questions

1. Which plugin channel-contribution contract represents `messageBoard` without adding PT semantics to a core channel type?
2. Should the plugin-contributed board tab be manually created or offered as an optional plugin profile?
3. Which PT-originated messages should the plugin render, given that the retired router sidecar will not coexist with it?
4. How should unread state behave when the board is receiving high-volume agent chatter?

## Implementation Bias

Prefer this shape:

- PT defines the data model and API
- Auxesis becomes the primary management UI
- the first-party Project Tracker plugin contributes a thin PT-backed view
- disabling or removing that plugin removes every PT-specific channel, command, badge, notification, and health state while the terminal remains complete
- existing inbox/outbox file conventions become optional legacy adapters

Avoid this shape:

- Holoscape invents a new board store
- Holoscape core polls PT or owns PT-specific channel lifecycle
- router log becomes the message source
- the retired router sidecar is restored as a delivery path
- Claude inbox/outbox becomes the permanent protocol
- Codex `.codex` internals become an integration target

## Immediate Next Steps

1. File a small Holoscape/PT card for notification hook client detection: include `Clawed` and `Codex`.
2. Hand this plan to Project Tracker as the architecture brief for board ownership.
3. Have PT decide the canonical board semantics on top of `messages`.
4. Once PT's contract exists, implement a PT-backed `Message Board` contribution in the optional first-party Project Tracker plugin, including tests that disabling the plugin removes the contribution without affecting core channels.
