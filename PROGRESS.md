# Session Progress — 2026-04-09

## Current State
- Branch: `fix/ui-tests-round3` (clean from main after PRs #35, #36, #37 merged)
- Full test suite running via `nohup` → `/tmp/test-results-round3.txt` (PID 36752)
- Last full run: 245 passed, 127 failed, 14 skipped (378 total)

## What was done today
1. Fixed "Application has not loaded accessibility" (134 tests) — `--ui-testing` launch arg skips heavy init
2. Fixed NSAlert button mapping — Bridge was response code 1003, should be 1004
3. Fixed HTTP body parsing — accumulate TCP data across multiple receive() calls
4. Fixed ShellChannelController — store explicit label (was silently discarding it)
5. Added close confirmation dialog for active channels
6. Fixed transparency slider value cast (NSNumber not String)
7. Added `--restore-channels` flag for restoration tests
8. Added sidebar auto-scroll to active entry
9. Created test sharding system (10 shards, ~8 min each)
10. Reverted sidebar identifier prefix change (broke CONTAINS matching)

## Still failing (~127 tests) — root causes
- Sidebar buttons not hittable (~30) — entries off-screen despite auto-scroll
- HTTP API tests (~20) — body accumulation fix needs verification
- Search match count (~7) — label populated but debounce + empty terminal buffer
- Channel restoration (~5) — --restore-channels flag needs test setup
- Close confirmation (~6) — dialog added but tests need verification
- Misc (~15) — font validation, URL scheme, bug report, window restore

## Next steps
1. Run full suite to get baseline with all PR #37 fixes
2. Investigate remaining sidebar hittability issue
3. Fix search match count for PTY channels
4. Individual test fixes for the misc category
