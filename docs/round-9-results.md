# Round 9 Results — P0 (`apiRequest` non-2xx throw)

**Date**: 2026-04-11
**Branch**: `fix/ui-tests-round9-p0-apirequest-errors`
**Commits on top of main (`5eb052d`)**:
- `9266e7e` — cousin Claude's round-9 deep-dive doc (`docs/round-9-deep-dive.md`)
- `f140529` — P0 fix: `apiRequest` throws `NSError` on non-2xx HTTP responses

## Headline

| | R8 | R9 | Delta |
|---|-----|-----|-------|
| Passed | 316 | **306** | −10 |
| Failed | 48 | **58** | +10 |
| Skipped | 6 | 6 | 0 |
| Pass rate | 86.8% | **84.1%** | −2.7pt |
| P0-surfaced raw throws | — | **37** | new signal |

**The pass rate drop is the whole point.** P0 stopped `apiRequest` from silently swallowing non-2xx HTTP responses. 37 of the 58 round-9 failures (64%) are raw `NSError` throws from the new guard — they point at previously-masked server errors (500 "Not ready", 404 "channel not found") that used to surface downstream as "sidebar entry not found" or "wrong accessibility value." Round 8's 86.8% was lying; round 9 is the honest baseline.

## Per-shard deltas

| Shard | Classes | R8 | R9 | R9 unexp | Delta | Notes |
|-------|---------|-----|-----|----------|-------|-------|
| 1 | IntegrityUITests | 41/10 | 41/13 | 12 | +3 | Almost all failures now raw throws |
| 2 | KeyboardShortcuts, WindowManagement | 34/5 | 34/4 | 2 | **−1** ✨ | Genuine improvement |
| 3 | Stress, ThemeSwitching | 31/2 | 31/4 | 4 | +2 | Stress-test races surfaced |
| 4 | SearchAdvanced, Settings, SessionLauncher | 44/8/3s | 44/8/3s | 0 | 0 | Real UI bugs (Bucket D/F) |
| 5 | FontSettings, EditMenu, ContextMenu | 42/1/3s | 42/1/3s | 0 | 0 | Near-clean both rounds |
| 6 | BugReport, HTTPAPI, Transparency | 33/4 | 33/**9** | 7 | **+5** | HTTPAPI exposes 5 new masked errors |
| 7 | Holoscape, TabBar, SplitPane, InputBox | 37/3 | 37/3 | 0 | 0 | All real UI bugs |
| 8 | ChannelOrder, Agent, SplitPane, Close | 31/0 | 31/0 | 0 | 0 ✅ | Clean both rounds |
| 9 | Bridge, TerminalInput, TabBehavior, Sidebar, SearchBar | 31/8 | 31/**9** | **8** | +1 | 8 of 9 failures newly surface as HTTP errors |
| 10 | URL, Terminal, SSH, NotificationSystem, ... | 46/7 | 46/7 | 4 | 0 (count) | NotificationSystem cold-start 500s exposed |
| **Total** | | **370/48/6** | **370/58/6** | **37** | +10 fails | |

## Diagnostic read

**37 "unexpected" NSError throws = the real triage signal.** They distribute as:

- **Bucket B (channel-creation race / "500 Not ready")** — 27 throws across shards 1 (12), 6 (7), 9 (8). Dominant cluster.
- **Bucket C (notification silent drop)** — 4 throws in shard 10 — NotificationSystemUITests cold-start matches cousin Claude's prediction exactly.
- **Bucket B stress variant** — 4 throws in shard 3 — StressUITests rapid channel creation.

**Bucket D (OSC 7 cd/label) and Bucket E (terminal focus) collapsed.** Cousin Claude theorized these needed their own fixes. But shard 9's 8 unexpected throws mean the TabBehavior cd tests and TerminalInput focus tests are **actually failing with HTTP errors under the hood** — `apiSendInput` returning 500 because `windowController` isn't ready, not label-pipeline or first-responder bugs. **Those buckets may not need their own fixes** — fixing Bucket B on the server side likely collapses them too.

## What moved / what didn't

**Honest improvements (real +1 passing)**:
- Shard 2: 5 → 4 failures (one KB/Window test is now passing that wasn't)

**Same-count but reclassified**:
- Shard 10 stays at 7 failures but 4 are now raw throws instead of silent failures. NotificationSystemUITests and related notification tests now fail with `500 Not ready` explicitly, confirming cousin Claude's in-isolation-vs-in-shard hypothesis.

**Unchanged**:
- Shard 8 still 0 failures ✅
- Shards 4, 5, 7 same as R8 with 0 unexpected — these clusters are **all real UI bugs**, not masked HTTP errors. P0 has no effect here. They'll need their own fixes (Bucket D/F).

## Next steps (ordered)

1. **P1** (this doc — done): Re-run with P0 and reclassify failures using the raw throws.
2. **P2 next**: Pull the actual error text from the 37 raw throws in the shard logs to verify they are "500 Not ready" (as predicted) vs something unexpected. Do not write a fix until the error text is confirmed.
3. **P3 after that**: Fix `handleCreateChannel` server-side to wait for `windowController` to be initialized before accepting `POST /channels`. Single fix expected to collapse ~27 of the 37 raw throws.
4. **P4**: `handleNotify` return 404 on channel-not-matched (Bucket C, 4 throws in shard 10).
5. **P5+**: Address the remaining 21 real UI failures (Bucket D/F) once the server-side dust settles.

## Key files

- `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:350-366` — `apiRequest` with new non-2xx guard
- `docs/round-9-deep-dive.md` — cousin Claude's root-cause triage
- `Sources/Holoscape/Services/HoloscapeAPIServer.swift:168-182` — `handleCreateChannel` (P3 target)
- `Sources/Holoscape/Services/HoloscapeAPIServer.swift:221-254` — `handleNotify` (P4 target)
- `Sources/Holoscape/Controllers/MainWindowController.swift:467-490` — `openChannel` reference
- `/tmp/holoscape-test-shards/shard-{1..10}.txt` — raw round-9 xcodebuild logs (source of truth for the 37 throws)
