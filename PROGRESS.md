# Session Progress — 2026-04-10

## Current State
- Branch: `fix/ui-tests-round6` (3 commits ahead of main)
- Estimated: ~270 passed, ~94 failed, 14 skipped (378 total)
- TransparencyColorWellUITests: 10/10 passing (was 4/10)
- BridgeChannelUITests: 7/7 passing (was 1/7)
- AgentChannelUITests: 8/8 passing (was 2/8)
- HTTPAPIUITests: 7/11 passing (was 5/11)

## Fixes applied this session
1. NSButton sidebar entries (PR #42) — flipped ~25 tests
2. nonisolated API helpers — prevents MainActor deadlock
3. apiReady reset in tearDown — prevents stale state across test instances
4. sliderValue() helper for all transparency reads — flipped 6 tests
5. --restore-channels launch arg in ChannelRestorationUITests

## The big remaining issue: OSC 7 sidebar labels (~50 tests)
- Shell channels start with displayLabel "Shell" but OSC 7 immediately changes it to "/"
- Sidebar identifier becomes "sidebar-/" instead of "sidebar-Shell"
- Tests searching for "Shell 2" never find it because it's now "/ 2"
- This affects: ChannelOrderingUITests, CloseConfirmationUITests, ContextMenuUITests,
  and any test that creates a second Shell via dialog
- NOT a bug — this is directory labels working correctly
- Need design decision: stable identifier vs dynamic display label

## Other remaining clusters
- Search match count (7) — API not connecting in some tests
- Close confirmation (7) — button disambiguation
- Window management (5) — minimize/restore/zoom
- Bug report (3) — feature implementation gaps
- Font size format (3) — "16.0" vs "16"
- Misc (~15) — individual issues

## Next steps
1. Solve the OSC 7 identifier issue — this is the single biggest remaining blocker
2. The right approach: separate stable accessibility identifier from dynamic display label
3. Could push up for code review on this design question
