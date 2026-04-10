# Session Progress — 2026-04-09 (evening)

## Current State
- Branch: `fix/ui-tests-round3-v2` (1 commit ahead of main: nonisolated API fix)
- Last full run: 239 passed, 125 failed, 14 skipped (378 total)
- HTTPAPIUITests: 9/11 passing (up from 5/11) after nonisolated fix
- PR #37 merged, PR for round3-v2 pending

## Key finding: sidebar isHittable issue
- ~22 tests fail because newly created sidebar entries return `isHittable == false`
- The entry EXISTS in accessibility tree, has correct frame, is within window bounds
- NOT caused by: scroll view clipping, coordinate conversion, layout timing, focus, window position
- IS caused by: XCTest accessibility hit testing on NSControl subclass inside NSStackView/NSScrollView
- The Shell entry created at launch IS hittable. Entries created via dialog are NOT.
- Pragmatic fix: update tests to use coordinate-based clicks instead of relying on isHittable
- Proper fix: investigate NSStackView accessibility interaction more deeply

## What still needs fixing
1. Sidebar isHittable (~22 tests) — need test-side workaround or deeper NSStackView investigation
2. Search match count (~7 tests) — debounce + empty terminal buffer
3. Close confirmation dialog (~7 tests) — dialog added but button matching issues
4. Transparency slider value (~6 tests) — cast fix needs verification
5. Font size format (~2 tests) — "16.0" vs "16"
6. Channel restoration (~2 tests) — --restore-channels flag in test setUp
7. Directory labels (~3 tests) — OSC 7 timing
8. Misc (~15 tests) — window management, bug report, URL scheme, input shrink

## Next steps
1. Fix sidebar isHittable — likely need to restructure SidebarTabEntry to be directly accessible
2. Fix remaining categories in order of impact
3. Run make test-ui-failing after each fix
