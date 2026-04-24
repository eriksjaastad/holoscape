# Project Tracker Message Board Plan

## Purpose

Define the split for an agent-to-agent message board feature where Project Tracker owns the messaging system and Holoscape only surfaces it as a channel.

This plan also carves out a separate, smaller task for CLI/client detection so notification behavior can expand to `Claude`, `Clawed`, and `Codex` without blocking the larger message-board work.

## What We Know

- Holoscape already has a local agent-router prototype in `tools/router/router.py` that routes `pt message` traffic into running tabs.
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

### Holoscape owns

- A `Message Board` channel type or profile
- Polling/rendering the PT-backed message feed inside one tab
- Input box for posting/replying into PT
- Optional unread badge / notification state for the board tab
- Optional deep links from a board item to a live agent tab

## Architecture Direction

### Source of truth

Use Project Tracker `messages` as the canonical ledger.

Do not use:

- `~/.claude/inbox` as the canonical board
- `~/.claude/outbox` as the canonical board
- `~/.codex` internals as the canonical board
- a Holoscape-local SQLite store as the canonical board

### Cross-computer model

Project Tracker should handle cross-computer state. Holoscape should consume PT's API or CLI-visible contract.

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

### Phase 2: Holoscape surface

Holoscape work:

- add a `Message Board` channel entry
- render PT messages in a single tab
- support posting a new message
- support reply to an existing message
- show sender, recipient, timestamp, reply target, and priority
- reuse as much of `GroupChatChannelController` as possible, but back it with PT instead of the existing group-chat backend

### Phase 3: Agent integration

After PT and Holoscape surface exist:

- router/agents can post into the same PT ledger
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

1. Do we create a new `messageBoard` channel type, or reuse `groupChat` with a PT-backed controller?
2. Should the board tab be a manually created channel or a built-in fixed session profile?
3. Should agent-router traffic remain invisible in normal tabs once the board exists, or should both surfaces coexist?
4. How should unread state behave when the board is receiving high-volume agent chatter?

## Implementation Bias

Prefer this shape:

- PT defines the data model and API
- Auxesis becomes the primary management UI
- Holoscape adds a thin PT-backed view
- existing inbox/outbox file conventions become optional legacy adapters

Avoid this shape:

- Holoscape invents a new board store
- router log becomes the message source
- Claude inbox/outbox becomes the permanent protocol
- Codex `.codex` internals become an integration target

## Immediate Next Steps

1. File a small Holoscape/PT card for notification hook client detection: include `Clawed` and `Codex`.
2. Hand this plan to Project Tracker as the architecture brief for board ownership.
3. Have PT decide the canonical board semantics on top of `messages`.
4. Once PT's contract exists, implement a PT-backed `Message Board` channel in Holoscape.
