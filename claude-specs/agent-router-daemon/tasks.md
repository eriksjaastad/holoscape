# Implementation Plan: Agent-to-Agent Router Daemon

## Overview

The router daemon is a standalone Python 3.11+ script at `~/projects/holoscape/tools/router/router.py` with ~200–300 lines. It talks to two backends: project-tracker's SQLite via the `pt` CLI and Holoscape's HTTP API on port 7865 via `urllib.request`. Two small changes are needed in other codebases: a two-field addition to Holoscape's `/channels` endpoint (Swift) and a one-column migration in project-tracker's messages table (SQLite).

Implementation order: Holoscape API addition first (unblocks everything), then schema migration, then daemon components bottom-up (poller → resolver → injector → detector → capturer → replier → logger → main loop), then integration test.

## Tasks

- [ ] 1. Holoscape API: Add `notification_type` and `is_active` to `/channels`
  - [ ] 1.1 Modify `handleListChannels()` in `Sources/Holoscape/Services/HoloscapeAPIServer.swift:142`
    - Add `"notification_type": channelNotifications[channel.channelId] as Any` to the channel dict
    - Add `"is_active": channel.channelId == activeId` to the channel dict (where `activeId = windowController?.activeChannelId`)
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5_
  - [ ] 1.2 Verify existing `HoloscapeMCP/Tools.swift:82-88` passes through the new fields in its `holoscape_list_channels` handler
    - The MCP tool formats the response as `[state] label (type) — id`. Either extend the format string to include notification_type, or leave it as-is (the daemon uses HTTP directly, not MCP)
    - _Requirements: 10.5_

- [ ] 2. Checkpoint
  - `swift build` and `swift test` pass with the API change. `curl http://localhost:7865/channels | python3 -m json.tool` shows `notification_type` and `is_active` fields.

- [ ] 3. Schema Migration: Add `processed_at` to messages table
  - [ ] 3.1 Add migration to project-tracker
    - Run `sqlite3 ~/projects/project-tracker/data/tracker.db "ALTER TABLE messages ADD COLUMN processed_at TEXT DEFAULT NULL;"`
    - Verify: `pt message list --json | python3 -c "import sys,json; [print(m.get('processed_at')) for m in json.load(sys.stdin)['messages']]"` shows `None` for all existing messages
    - _Requirements: 11.1, 11.5_
  - [ ] 3.2 Modify `check_chat.sh` at `~/projects/project-tracker/agent-chat/hooks/check_chat.sh`
    - Add a filter to skip messages where `processed_at` is not null
    - _Requirements: 11.4_

- [ ] 4. Checkpoint
  - `pt message list --json` works. `check_chat.sh` skips a test message marked with `processed_at`.

- [ ] 5. Router Daemon: Core Components
  - [ ] 5.1 Create `~/projects/holoscape/tools/router/router.py` with `ExchangeLogger` class
    - Append-only file logger with ISO-8601 timestamps
    - Methods: `exchange()`, `bounce()`, `hold()`, `error()`, `startup()`
    - Log path: `~/projects/holoscape/tools/router/router.log`
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7_
  - [ ] 5.2 Add `MessagePoller` class to `router.py`
    - `poll(watermark)`: calls `pt message list --json`, filters by recipient not null, ts > watermark, processed_at null, sorted oldest-first
    - `mark_processed(message_id)`: direct SQLite UPDATE on `~/projects/project-tracker/data/tracker.db` setting `processed_at` to current UTC ISO-8601
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 5.1, 11.2, 11.3_
  - [ ] 5.3 Add `ChannelResolver` class to `router.py`
    - `resolve(recipient)`: GET `http://localhost:7865/channels`, match label case-insensitive, check aliases dict
    - `is_foreground(channel)`: returns `channel['is_active']`
    - `AGENT_ALIASES` dict with `{"architect": "projects"}` default
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.1_
  - [ ] 5.4 Add `MessageInjector` class to `router.py`
    - `wrap(sender, body)`: returns `[Agent message from: {sender}]\n{body}\n[Respond conversationally...]`
    - `inject(channel_id, sender, body)`: wraps, appends `\n`, POSTs to `/channels/{id}/input`
    - _Requirements: 5.2, 5.3, 5.4, 5.5, 5.7, 6.1, 6.2, 6.3, 6.4, 6.5_
  - [ ] 5.5 Add `ResponseDetector` class to `router.py`
    - `wait_for_response(channel_id)`: polls GET `/channels` every 2s, watches `notification_type` for target channel
    - Returns `"complete"` on `idle_prompt`, `"permission_blocked"` on persistent `permission_prompt`, `"timeout"` after 120s
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_
  - [ ] 5.6 Add `ResponseCapture` class to `router.py`
    - `capture(channel_id)`: GET `/channels/{id}/output?lines=100`, extract response text, truncate at 4000 chars if needed
    - _Requirements: 8.1, 8.2, 8.4_
  - [ ] 5.7 Add `ReplyRouter` class to `router.py`
    - `reply(original_sender, response_text)`: calls `pt message send "{response}" --to {sender}`
    - `bounce(original_sender, recipient, reason)`: sends bounce notification
    - _Requirements: 3.3, 8.3, 8.6_

- [ ] 6. Checkpoint
  - Each class is importable and individually testable. `python3 -c "from router import MessagePoller, ChannelResolver, MessageInjector, ResponseDetector, ResponseCapture, ReplyRouter, ExchangeLogger"` succeeds.

- [ ] 7. Router Daemon: Main Loop and Lifecycle
  - [ ] 7.1 Add `RouterDaemon` class to `router.py`
    - `__init__()`: set startup watermark, register SIGINT/SIGTERM handlers, create lock file (check for stale lock via PID), instantiate all component classes
    - `run()`: polling loop with `POLL_INTERVAL = 3.0` sleep between cycles
    - `shutdown()`: remove lock file, log shutdown, exit cleanly
    - Per-cycle logic: poll → for each message → resolve → check foreground → inject or hold → detect response → capture → reply → log
    - Held messages: maintain a list, re-check foreground status each cycle
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 4.2, 4.3, 4.4, 4.5, 5.6, 8.5, 12.1, 12.2, 12.3, 12.4_
  - [ ] 7.2 Add `if __name__ == "__main__"` entry point
    - Parse optional `--interval` flag (default 3.0)
    - Parse optional `--api-url` flag (default `http://localhost:7865`)
    - Instantiate and run `RouterDaemon`
    - _Requirements: 1.2_

- [ ] 8. Checkpoint
  - Start the daemon: `python3 ~/projects/holoscape/tools/router/router.py`
  - Verify lock file created at `~/projects/holoscape/tools/router/router.lock`
  - Verify `router.log` contains startup entry
  - Ctrl+C: verify lock file removed and clean exit
  - Start a second instance: verify it exits with "another instance is running" error

- [ ] 9. Unit Tests
  - [ ] 9.1 Create `~/projects/holoscape/tools/router/tests/test_message_poller.py`
    - Test filtering by recipient, watermark, processed_at
    - Test chronological ordering
    - Test self-addressed message skip
    - _Requirements: 2.1, 2.2, 2.5_
  - [ ] 9.2 Create `~/projects/holoscape/tools/router/tests/test_channel_resolver.py`
    - Test case-insensitive label matching
    - Test alias resolution
    - Test no-match returns None
    - _Requirements: 3.1, 3.2, 3.3_
  - [ ] 9.3 Create `~/projects/holoscape/tools/router/tests/test_message_injector.py`
    - Test wrapper format matches spec exactly
    - Test newline appended
    - Test body is not modified
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_
  - [ ] 9.4 Create `~/projects/holoscape/tools/router/tests/test_response_detector.py`
    - Test idle_prompt → complete
    - Test permission_prompt → warning + continue
    - Test timeout after 120s (mocked time)
    - _Requirements: 7.2, 7.3, 7.4_
  - [ ] 9.5 Create `~/projects/holoscape/tools/router/tests/test_response_capture.py`
    - Test extraction from mock output
    - Test truncation at 4000 chars
    - Test truncation notice appended
    - _Requirements: 8.2, 8.4_
  - [ ] 9.6 Create `~/projects/holoscape/tools/router/tests/test_daemon_lifecycle.py`
    - Test lock file creation and cleanup
    - Test stale lock detection via dead PID
    - Test watermark set on init
    - _Requirements: 1.3, 1.4, 1.5, 12.1_

- [ ]* 10. Property-Based Tests (optional)
  - [ ]* 10.1 Create `~/projects/holoscape/tools/router/tests/test_properties.py`
    - **Property 1 (No Double Injection):** generate message sequences, assert mark_processed before inject
    - **Property 3 (Foreground Protection):** generate is_active sequences, assert no inject when True
    - **Property 4 (Watermark Monotonicity):** generate timestamps around boundary, assert correct filtering
    - **Property 6 (Wrapper Integrity):** generate arbitrary bodies, assert exact wrapper template
    - **Property 10 (Response Truncation):** generate varying-length responses, assert length bound
    - **Validates: Requirements 5.1, 4.1, 12.2, 6.1-6.5, 8.4**

- [ ] 11. Checkpoint
  - All unit tests pass: `cd ~/projects/holoscape/tools/router && python3 -m pytest tests/`

- [ ] 12. Integration Test (manual)
  - [ ] 12.1 End-to-end smoke test
    - Start Holoscape with two Claude Code channels
    - Start the router daemon
    - From channel A: `pt message send "What are you working on?" --to <channel-B-label>`
    - Observe injection in channel B, response generated, reply delivered to channel A
    - Verify `router.log` contains the complete exchange
    - Verify `pt message list --json` shows `processed_at` set on the original message
    - _Requirements: All_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- The daemon is a single file (`router.py`) — all classes live in the same module. If it grows past 400 lines, split into a package, but V1 should stay under 300.
- The Holoscape Swift change (task 1) and schema migration (task 3) can be done in parallel since they're independent
- The `check_chat.sh` modification (task 3.2) requires coordination with the project-tracker floor manager — flag it early
