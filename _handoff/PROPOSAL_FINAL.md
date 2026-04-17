# PROPOSAL_FINAL.md

## Feature: Agent-to-Agent Router Daemon
**Date:** 2026-04-16
**PRD:** docs/agent-router-prd.md
**Kiro Specs:** claude-specs/agent-router-daemon/
**Traceability:** TRACED — 2 descoped gaps (rate limiting, shutdown notification), both with clean rationales. No dropped requirements.

## Objective

Erik manages 5–10 concurrent Claude Code agents across Holoscape tabs and manually relays messages between them 6+ times per day. The cognitive interrupt cost of each relay exceeds the time cost — every copy-paste breaks focus on active work.

The router daemon is a standalone Python sidecar (~200–300 lines) that automates this relay. It polls `pt message` for directed inter-agent messages, resolves the target agent to a running Holoscape channel by label, injects the message via the existing HTTP API on port 7865, detects response completion via the existing `idle_prompt` notification signal, captures the response, and routes it back. All infrastructure exists today — this is wiring, not invention.

V1 goal: Erik goes a full working day without manually relaying a single agent-to-agent message.

## Acceptance Criteria

### Daemon Lifecycle
- [ ] Daemon starts, records startup watermark, begins polling at 3–5s interval
- [ ] Lock file prevents concurrent instances; stale locks detected via PID check
- [ ] SIGINT/SIGTERM removes lock file and exits cleanly
- [ ] Connection failures to Holoscape API logged and retried, never crash

### Message Pipeline
- [ ] Polls `pt message` for directed messages (recipient not null, ts > watermark, processed_at null)
- [ ] Resolves recipient to Holoscape channel by label (case-insensitive) or alias config
- [ ] Offline agents get a bounce message back to the sender
- [ ] Messages for the foreground tab are held until Erik switches away
- [ ] Messages wrapped with safety header stripping user-level authority
- [ ] Wrapped message injected via POST `/channels/{id}/input` with trailing newline
- [ ] `processed_at` set BEFORE injection (mark-before-inject deduplication)
- [ ] Response detected via `idle_prompt` notification type (120s timeout fallback)
- [ ] Response captured from channel output, truncated at 4000 chars
- [ ] Response routed back to sender via `pt message send --to`

### Holoscape API Additions
- [ ] GET `/channels` response includes `notification_type` per channel (`idle_prompt` / `permission_prompt` / null)
- [ ] GET `/channels` response includes `is_active` boolean per channel (foreground tab flag)
- [ ] Existing fields (`id`, `label`, `type`, `state`) unchanged

### Schema & Hook Changes
- [ ] `messages` table gains `processed_at` TEXT column (nullable, default NULL)
- [ ] `check_chat.sh` skips messages where `processed_at` is not null

### Logging
- [ ] Every exchange logged: sender, recipient, message preview, response preview, duration, status
- [ ] Bounces, holds, and errors logged with full context
- [ ] Append-only log at `~/projects/holoscape/tools/router/router.log`

## Technical Design Summary

### Storage Strategy

| Store | Location | What | Change? |
|-------|----------|------|---------|
| Messages | `~/projects/project-tracker/data/tracker.db` → `messages` table | Inter-agent messages with `sender`, `recipient`, `body`, `ts`, `processed_at` | **ADD COLUMN** `processed_at TEXT DEFAULT NULL` |
| Router log | `~/projects/holoscape/tools/router/router.log` | Append-only exchange log (timestamp, sender, recipient, previews, duration, status) | **NEW FILE** (created at runtime) |
| Lock file | `~/projects/holoscape/tools/router/router.lock` | PID of running daemon instance | **NEW FILE** (created/removed at runtime) |
| Alias config | `~/projects/holoscape/tools/router/router.py` (inline dict) | Agent name → channel label overrides, e.g. `{"architect": "projects"}` | **NEW** (part of daemon source) |
| Holoscape notification state | `HoloscapeAPIServer.channelNotifications` (in-memory dict) | Per-channel `idle_prompt` / `permission_prompt` / nil | **NO CHANGE** (already exists, just exposed via API) |
| Active channel ID | `MainWindowController.activeChannelId` (in-memory UUID?) | Which tab is foreground | **NO CHANGE** (already exists, just exposed via API) |

### State Machine

```
Message arrives in pt_message
    │
    ▼
[PENDING] ─── recipient not null, ts > watermark, processed_at null
    │
    ├── recipient not found ──► [BOUNCED] → send bounce to sender
    │
    ├── target is foreground ──► [HELD] → re-check each poll cycle
    │                              │
    │                              ├── target becomes background ──► [INJECTING]
    │                              └── target goes offline ──► [BOUNCED]
    │
    └── target is background ──► [INJECTING]
                                    │
                                    ├── mark processed_at (BEFORE injection)
                                    ├── wrap with safety header
                                    ├── POST /channels/{id}/input
                                    │
                                    ▼
                              [DETECTING] ── poll notification_type every 2s
                                    │
                                    ├── idle_prompt ──► [CAPTURING]
                                    ├── permission_prompt ──► wait (may resolve)
                                    └── 120s timeout ──► [CAPTURING] (partial)
                                              │
                                              ▼
                                        [CAPTURING]
                                              │
                                              ├── GET /channels/{id}/output
                                              ├── extract response text
                                              ├── truncate at 4000 chars if needed
                                              │
                                              ▼
                                        [REPLYING]
                                              │
                                              ├── pt message send --to sender
                                              ├── log exchange to router.log
                                              │
                                              ▼
                                        [COMPLETE]
```

### Publishing Pipeline

No "publishing" in the traditional sense. The daemon is a message relay:
- **Inbound:** messages arrive in `pt message` (SQLite). Daemon polls.
- **Injection:** daemon POSTs to Holoscape HTTP API. Text appears in Claude Code session's terminal as if Erik typed it.
- **Outbound:** response routed back via `pt message send --to`. The requesting agent sees it next time it polls or its `check_chat.sh` hook fires.

The exchange is visible to Erik live in the Holoscape tab where the injection happens. No separate publication step.

### Notification Events

| Event | Recipient | Channel |
|-------|-----------|---------|
| Message injected into session | Erik (via Holoscape tab, live) | Terminal output in target tab — no separate notification needed |
| Message bounced (agent offline) | Sending agent | `pt message send --to <sender>` with bounce reason |
| Message held (foreground protection) | Router log only | `router.log` entry — Erik doesn't see this unless he reads the log |
| Response delivered to sender | Sending agent | `pt message send --to <sender>` with response text |
| Timeout (no idle_prompt in 120s) | Router log + sending agent | Log entry + partial response delivered |
| Daemon startup/shutdown | Router log only | `router.log` entry |

## Implementation Tasks

### Phase 1: API & Schema (unblocks everything)

| # | Task | Done When | Requirements |
|---|------|-----------|--------------|
| 1.1 | Modify `HoloscapeAPIServer.swift:142` — add `notification_type` and `is_active` to `/channels` response | `curl localhost:7865/channels` returns both new fields; `swift build` + `swift test` pass | 10.1–10.5 |
| 1.2 | Verify `HoloscapeMCP/Tools.swift:82` passthrough | MCP tool output format documented; daemon confirmed to use HTTP directly | 10.5 |
| 3.1 | `ALTER TABLE messages ADD COLUMN processed_at TEXT DEFAULT NULL` in project-tracker SQLite | `pt message list --json` returns `processed_at: null` for all messages | 11.1, 11.5 |
| 3.2 | Update `check_chat.sh` to skip messages where `processed_at IS NOT NULL` | Hook doesn't surface already-processed messages | 11.4 |

### Phase 2: Daemon Components (bottom-up)

| # | Task | Done When | Requirements |
|---|------|-----------|--------------|
| 5.1 | Create `router.py` with `ExchangeLogger` | Log file created, ISO-8601 timestamps, all 5 log methods work | 9.1–9.7 |
| 5.2 | Add `MessagePoller` | `poll()` returns filtered/sorted messages; `mark_processed()` writes to SQLite | 2.1–2.5, 5.1, 11.2–11.3 |
| 5.3 | Add `ChannelResolver` | Label matching (case-insensitive), alias resolution, foreground check, None on miss | 3.1–3.5, 4.1 |
| 5.4 | Add `MessageInjector` | Wrapper format exact-matches spec; POST to /channels/{id}/input succeeds; newline appended | 5.2–5.5, 5.7, 6.1–6.5 |
| 5.5 | Add `ResponseDetector` | Returns "complete" on idle_prompt, "timeout" after 120s, handles permission_prompt | 7.1–7.6 |
| 5.6 | Add `ResponseCapture` | Extracts response text from output; truncates at 4000 chars | 8.1, 8.2, 8.4 |
| 5.7 | Add `ReplyRouter` | Sends reply via `pt message send --to`; sends bounce on failure | 3.3, 8.3, 8.6 |

### Phase 3: Main Loop & Lifecycle

| # | Task | Done When | Requirements |
|---|------|-----------|--------------|
| 7.1 | Add `RouterDaemon` class | Lock file created/cleaned; watermark set; SIGINT handled; held messages re-checked each cycle; foreground protection works end-to-end | 1.1–1.7, 4.2–4.5, 12.1–12.4 |
| 7.2 | Add `__main__` entry point | `python3 router.py` starts daemon; `--interval` and `--api-url` flags work | 1.2 |

### Phase 4: Tests

| # | Task | Done When | Requirements |
|---|------|-----------|--------------|
| 9.1–9.6 | Unit tests (6 files) | `pytest tests/` all pass | 1.3–1.5, 2.1–2.5, 3.1–3.3, 6.1–6.5, 7.2–7.4, 8.2, 8.4, 12.1 |
| 10.1* | Property-based tests (optional) | Hypothesis tests pass for properties 1, 3, 4, 6, 10 | 4.1, 5.1, 6.1–6.5, 8.4, 12.2 |
| 12.1 | Manual integration test | End-to-end: message sent → injected → response captured → reply delivered; router.log has the record | All |

## Traceability

| PRD Intent | Requirements | Tasks | Status |
|-----------|-------------|-------|--------|
| Eliminate manual relay | 2, 3, 5, 7, 8 | 5.2–5.7, 7.1 | ✓ |
| Preserve live context | 5 | 5.4 | ✓ |
| Protect focus | 4 | 5.3, 7.1 | ✓ |
| Safety boundaries | 6 | 5.4 | ✓ |
| Holoscape API additions | 10 | 1.1, 1.2 | ✓ |
| Schema change | 11 | 3.1, 3.2 | ✓ |
| Startup watermark | 12 | 7.1 | ✓ |
| Daemon lifecycle | 1 | 7.1, 7.2 | ✓ |
| Logging | 9 | 5.1 | ✓ |
| Rate limiting | — | — | DESCOPED: sequential processing (Req 7.6) is natural throttle |
| Shutdown notification | — | — | DESCOPED: silent stop is correct default |

## Dependencies

| Dependency | Owner | Status | Blocks |
|-----------|-------|--------|--------|
| Holoscape running on port 7865 | Holoscape (this project) | ✓ Exists | All daemon operations |
| `pt message` CLI | project-tracker | ✓ Exists | Tasks 5.2, 5.7 |
| `pt message list --json` output format | project-tracker | ✓ Verified (fields: id, body, sender, recipient, priority, metadata, reply_to, ts) | Task 5.2 |
| `channelNotifications` dict in HoloscapeAPIServer | Holoscape | ✓ Exists at `HoloscapeAPIServer.swift:13` | Task 1.1 |
| `activeChannelId` in MainWindowController | Holoscape | ✓ Exists at `MainWindowController.swift:23` | Task 1.1 |
| `check_chat.sh` hook | project-tracker | ✓ Exists at `~/projects/project-tracker/agent-chat/hooks/check_chat.sh` | Task 3.2 |
| Python 3.11+ | System | ✓ Available via `uv run` | All daemon code |
| `processed_at` column in messages table | project-tracker | **NEEDS MIGRATION** | Tasks 5.2, 3.1 |
| `notification_type` + `is_active` on /channels | Holoscape | **NEEDS 6-LINE SWIFT CHANGE** | Tasks 5.3, 5.5 |

## Out of Scope

- **Multi-turn threading** — V1 is one-shot request→response. Threading is V2 after learning from real usage.
- **Auto-spawning sessions** — messages to offline agents bounce immediately. No `holoscape_open_channel` automation.
- **Aggregate chat UI** — no new Holoscape views. Erik watches exchanges in the tab where they happen.
- **Structured message format** — free-form text, no JSON schema, no threading metadata.
- **Push notifications / WebSocket** — polling only.
- **Message queuing for offline agents** — immediate bounce, no retry queue.
- **Rate limiting** — sequential processing (one exchange at a time per channel) is the natural throttle.
- **Shutdown notification to agents** — daemon stops silently, removes lock file.
- **Shader pipeline cards (#5930 series)** — completely independent track, not touched.

## Execution Notes for the Worker

1. **Start with Task 1.1** (Swift API change). It's a 6-line modification to an existing function. Build and test before anything else — this unblocks the entire daemon.
2. **Task 3.1 (schema migration) can run in parallel** with Task 1.1. It's an ALTER TABLE on a different codebase.
3. **Task 3.2 (check_chat.sh)** requires coordination with the project-tracker floor manager. Flag it early — it's a one-line filter addition, but it touches another project's hook.
4. **The daemon is a single file** (`router.py`). All 7 component classes live in the same module. Don't split into a package unless it exceeds 400 lines.
5. **Use `doppler run --` for any script that needs secrets.** The daemon itself doesn't need secrets (it talks to local SQLite and a localhost HTTP API), but `pt` CLI calls go through Doppler per project rules.
6. **The `processed_at` SQLite UPDATE is the one exception** to the "use `pt` CLI for everything" rule. The CLI doesn't expose a "mark as processed" command, so the daemon hits the database directly for this one operation.
7. **Manual integration test (Task 12.1)** is the real acceptance gate. Unit tests verify components; the integration test verifies the whole loop. Don't skip it.
