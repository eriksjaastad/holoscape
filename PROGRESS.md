# Session Progress — 2026-04-10 (late afternoon)

## Current State
- Branch: `fix/ui-tests-round6` (11 commits ahead of main)
- Full shard run: 293 passed, 71 failed, 14 skipped (378 total) — 78% pass rate

## Perfect score classes (100%)
- FontSettingsUITests (13/13)
- EditMenuUITests (13/13)
- TransparencyColorWellUITests (10/10)
- ChannelOrderingUITests (9/9)
- AgentChannelUITests (8/8)
- BridgeChannelUITests (7/7)
- SidebarUITests (6/6)
- ThemeSwitchingUITests (15/15)
- SettingsUITests (13/13)
- KeyboardShortcutsUITests (18/18)
- HoloscapeUITests (10/10)
- SplitPaneUITests (7/7)

## Remaining 71 failures — all cluster around API timing race
- IntegrityUITests (15) — depends on apiCreateChannel + apiSendInput
- TabBehaviorUITests (6) — cd commands via API, wait for label update
- TerminalInputUITests (4) — API send input, waitForAPIOutput
- SearchAdvancedUITests (6) — search for text sent via API
- StressUITests (4) — bulk API operations
- NotificationSystemUITests (4) — API-created channels + notify
- HTTPAPIUITests (3) — testCreateChannelWithDirectory, testSendInput, testResolveByLabelCase
- WindowManagementUITests (5) — minimize/restore/zoom XCTest limits
- CloseConfirmationUITests (1) — testCloseLastChannelBehavior
- Plus ~23 more in misc classes, mostly API-dependent

## The core architectural issue
All failing tests share: create/send via API, then query and expect result.
The API timing race is hard to solve without:
1. Random port per test (bigger change)
2. App process isolation (each test its own process tree)
3. Waiting on BOTH port-free AND new-app-responsive states (tried, flaky)

## What was fixed this session (Groups 1-6)
1. API tearDown delay + nonisolated helpers + saveState skip
2. Close confirmation dialog button scoping
3. Font size integer format + non-numeric validation
4. Bug report screenshot accessibility label + validation sheet
5. Context menu duplicate fallback for UI testing mode
6. Window minimize/restore via Cm+backtick, About dialog dismiss
7. Transparency slider NSNumber cast
8. Sidebar index-based lookups (OSC 7 label changes)
9. NSButton sidebar entries (native accessibility)
10. ChannelRestoration --restore-channels launch arg
