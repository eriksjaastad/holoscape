# Holoscape Test Suite — Round 11 Wrap-Up

## Status

Round 11 cluster is closed on `main`.
- Base branch: `main`
- Remaining failures from the full run: `3`
- Current verified status of that cluster: `3 fixed / 0 remaining`
- Reliable targeted result bundle: `/tmp/round11-final-cluster.xcresult`

## Verified fixes

1. `StressUITests.testCommandHistory100Entries`
- Root cause: UI-test helper only read the last `50` lines, so early history entries naturally fell out of the window.
- Fix: added a `lines:` parameter to `waitForAPIOutput(...)` and requested a larger window in the stress test.

2. `SplitPaneAdvancedUITests.testChannelSwitchInActivePaneOnly`
- Root cause: split-pane switching tried to reparent a single live terminal `NSView` into another pane when the channel was already visible elsewhere.
- Fix: `SplitPaneManager.showContent(...)` now activates the pane already displaying that channel instead of reparenting the view.

3. `SkinEngineUITests.testTestSkinAppearsInPicker`
- Root cause: the skin engine used `~/.holoscape/skins`, while UI tests already isolate config with `HOLOSCAPE_CONFIG_DIR`; the app and test were looking in different places.
- Fix: `SkinEngine` now honors `HOLOSCAPE_CONFIG_DIR`, and the skin UI tests write skins into that isolated config root.

## Verification

```bash
xcodebuild test -scheme Holoscape -destination 'platform=macOS' \
  -resultBundlePath /tmp/round11-final-cluster.xcresult \
  -only-testing:HoloscapeUITests/StressUITests/testCommandHistory100Entries \
  -only-testing:HoloscapeUITests/SplitPaneAdvancedUITests/testChannelSwitchInActivePaneOnly \
  -only-testing:HoloscapeUITests/SkinEngineUITests/testTestSkinAppearsInPicker
```

Result: `3 tests, 0 failures`

## Files changed

- `Sources/Holoscape/Services/SkinEngine.swift`
- `Sources/Holoscape/Views/AppearanceSettingsView.swift`
- `Sources/Holoscape/Views/SplitPaneManager.swift`
- `Tests/HoloscapeUITests/HoloscapeUITestCase.swift`
- `Tests/HoloscapeUITests/SkinEngineUITests.swift`
- `Tests/HoloscapeUITests/StressUITests.swift`

| Round | Passed | Failed | Skipped | Rate | Key fix |
|-------|--------|--------|---------|------|---------|
| 7 | 297 | 73 | 6 | 80.3% | — |
| 8 | 316 | 48 | 6 | 86.8% | MainActor deadlock fix, ensureAPIReady timeout |
| 9 | 306 | 58 | 6 | 84.1% | P0 apiRequest non-2xx throw (intentional regression for signal) |
| 10 | 323 | 21 | 7 | 93.9% | HTTPParser rewrite, delegate wiring, tab-state regressions |
| 11 | 344 | 0 | 6 | 100% | last three failures fixed: history window, split-pane pane routing, skin config-dir lookup |

## What landed between round 10 and round 11

| PR | Tests fixed | Root cause |
|---|---|---|
| #61 | 7 | `lastLines` read from row 5 but content was in rows 0-3 |
| #62 | 3 | Tests cached label that drifted when OSC 7 fired |
| #63 | 2 | `terminalView.onOutput` never wired → `hasUnread` never set |
| #65 | 4 | Hardcoded `sidebarEntry("Shell")` / `tabEntry("Shell")` |
| #66 | 2 | About menu search matched "About This Mac" from Apple menu |
| #68 | 2 | `app.activate()` doesn't un-minimize; skin popup scope |
