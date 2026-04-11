# Session Progress — 2026-04-11

## Current State
- Branch: `claude/optimize-local-claude-BxJW9` (1 commit ahead of main)
- Previous: 293 passed, 71 failed (78% pass rate)
- Expected after this fix: all 71 failures addressed across 6 clusters

## What was fixed this session

### Cluster A: API Timing Race (~40 tests) — ROOT CAUSE FIX
- **Problem**: All tests shared hardcoded port 7865. Port release race between test runs caused stale API responses.
- **Fix**: Per-test random port in ephemeral range (49152-60999), passed via `--api-port` launch argument.
- Changed: HoloscapeAPIServer (port parameter), AppDelegate (--api-port arg), HoloscapeUITestCase (random port generation), IntegrityUITests + NotificationSystemUITests (custom setUp with port)
- Removed: 0.5s tearDown sleep (no longer needed)

### Cluster B: Search Match Count (~7 tests)
- **Problem**: Terminal buffer not rendered when search runs.
- **Fix**: `waitForAPIOutput` before searching + increased `searchMatchCountText` timeout to 5s.

### Cluster C: Window Management (5 tests)
- Added Window menu (Minimize, Zoom, Bring All to Front) + `NSApp.windowsMenu`
- Fixed minimize/restore tests to use Window menu
- Fixed About dialog tests to use Cmd+W for dismiss

### Cluster D: Bug Report NSAlert (2 tests)
- Changed `beginSheetModal` to `runModal` for both validation and confirmation alerts
- Fixed test to query `app.alerts` instead of `app.dialogs`

### Cluster E: Context Menu (3 tests)
- Added close confirmation to `contextMenuClose` (was bypassing for active channels)
- Set `menu.autoenablesItems = false` (NSMenu was overriding Reconnect isEnabled)
- Fixed Copy Session Info test to read clipboard directly

### Cluster F: Miscellaneous (~14 tests)
- Auto-create fresh shell when last channel closed
- InputBoxView: `didChangeText()` after clearing for layout recalculation
- Fixed OSC 7 label assumptions (use `firstSidebarEntry()`/index-based lookups)
- Fixed slider assertion to use `normalizedSliderPosition`
- Fixed tab bar tests to match any `tab-` prefix
- Fixed pin persistence: save state in `applicationWillTerminate` when `--restore-channels`
- Added per-channel wait in stress tests
- Added timing tolerance to split pane tests

## Architecture decisions
- Port 7865 remains the default for production/MCP usage
- Test port range 49152-60999 avoids conflicts with well-known ports
- `currentAPIBase` is a class-level static for thread safety across nonisolated helpers
