# Session Progress — 2026-04-10

## Current State
- Branch: `fix/ui-tests-round6` (1 commit ahead of main: apiReady reset)
- Last full run: 264 passed, 100 failed, 14 skipped (378 total) — 70% pass rate
- Up from 58 passing (15%) two days ago

## Key discovery: OSC 7 changes sidebar identifiers
- ~23 tests search for "Shell 2" in sidebar but OSC 7 changes displayLabel from "Shell" to "/"
  (the home directory basename) almost immediately after shell creation
- The sidebar identifier "sidebar-Shell 2" becomes "sidebar-/ 2" before the test can find it
- This is NOT a bug — it's the directory label feature working correctly
- Need a solution that preserves directory labels AND lets tests find entries reliably

## Remaining failure clusters (100 tests)
1. **Shell 2 / directory label conflict** (~23) — OSC 7 changes identifier before test finds it
2. **API batch failures** (~26) — apiReady reset should fix many; some are downstream of cluster 1
3. **Search match count** (~7) — debounce + empty terminal buffer
4. **Close confirmation dialog** (~7) — dialog exists but test can't find buttons
5. **Transparency slider** (~6) — value cast issue
6. **Directory persistence** (~3) — OSC 7 timing + --restore-channels flag
7. **Channel restoration** (~2) — --restore-channels flag needed in test setUp
8. **Window management** (~5) — minimize/restore/zoom/about dialog
9. **Misc** (~15) — bug report, fonts, URL scheme, individual issues

## What was fixed today
- NSButton sidebar entries (PR #42) — flipped 25 tests
- nonisolated API helpers (prevents MainActor deadlock)
- apiReady reset in tearDown
- Window maximization during UI testing

## Next steps
1. Fix cluster 1: either add instance-based sidebar search helper, or set explicitLabel on
   dialog-created shells so displayLabel stays "Shell 2" until user cds somewhere
2. Verify apiReady fix helps cluster 2
3. Work through remaining clusters
