# Session Progress — 2026-04-10 (afternoon)

## Current State
- Branch: `fix/ui-tests-round6` (9 commits ahead of main)
- Full run: 291 passed, 73 failed, 14 skipped (378 total) — 77% pass rate
- Up from 58 passing (15%) three days ago

## Remaining 73 failures by cluster
- IntegrityUITests (15) — integration tests, depend on API + search + notifications
- TabBehaviorUITests (6) + DirectoryPersistenceUITests (3) — OSC 7 cd timing
- SearchAdvancedUITests (6) + SearchBarUITests (1) — search match count empty
- API-dependent: TerminalInput (4), HTTP (4), Stress (5), Notification (4) — 17 total
- WindowManagementUITests (5) — minimize/restore/zoom XCTest limitations
- Misc: ContextMenu (3), TabBar (2), SplitPane (2), Session (2), etc.

## Root causes identified
1. API channel label resolution fails after OSC 7 changes displayLabel
2. Search match count empty — terminal buffer not populated when search runs
3. cd /tmp doesn't trigger visible OSC 7 update in test environment
4. Window minimize/restore not working via app.activate() in XCTest
5. testCreateChannelWithDirectory returns 400 — dir parameter handling

## Next steps
1. Fix API label resolution — resolveChannel should match by original role, not just displayLabel
2. Fix search — ensure terminal buffer has content before searching
3. Fix directory test timing — longer waits or different approach for OSC 7
4. IntegrityUITests should improve as upstream fixes land
