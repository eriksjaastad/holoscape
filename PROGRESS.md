# Session Progress — Shell Channel Delegate Wiring (2026-04-11)

## Status

- Branch: `fix/shell-channel-delegate-wiring` (PR pending)
- Carries forward prior session's unpushed tab-state-regression follow-ups + the new delegate fix

## Root cause

The default shell channel was being created at two sites without ever
assigning `channel.delegate`, so every `channelStateDidChange` call (OSC 7
directory updates, the `applyDirectoryFallback` cd path, state transitions)
was dropped on the floor. Internal state updated; no one notified the window
controller to refresh the sidebar/tab bar.

**Fix sites**:
- `Sources/Holoscape/AppDelegate.swift:83` — default shell on app launch
- `Sources/Holoscape/Controllers/MainWindowController.swift:648` — replacement shell when the last channel is closed

Both now set `channel.delegate = windowController` / `= self` before `activate()`.

## Diagnosis path

File-based diagnostic in `ShellChannelController` (removed before commit) confirmed:

```
sendInput id=… state=active text=cd /tmp\n
applyDirectoryFallback update / -> /tmp, displayLabel will be: tmp
applyDirectoryFallback delegate=nil, calling channelStateDidChange
applyDirectoryFallback post-delegate displayLabel=tmp
```

Internal `workingDirectory` updated correctly; `displayLabel` returned `"tmp"` immediately; but `delegate=nil` meant no refresh fired. The prior session's cd-fallback logic in `applyDirectoryFallback` was correct — it just had no listener.

## Verified green after fix

- **`TabBehaviorUITests` — 6/6** (including `testCdUpdatesTabLabel`, `testCdToAnotherDirectoryUpdatesLabel`, `testLabelsPeristAcrossRestart`)
- **`DirectoryPersistenceUITests` — 2/3** (`testCdChangesLabelToDirectoryName`, `testDirectoryPersistsAcrossRestart`)

## Test harness changes

To unblock the persistence tests:

1. `ConfigService.swift` — added `HOLOSCAPE_CONFIG_DIR` env-var override so each test can use an isolated config directory. Keeps the existing `--ui-testing` save guard intact (no production save-guard logic changed).
2. `DirectoryPersistenceUITests.swift` — custom `setUpWithError` that:
   - Creates a per-test `/tmp/holoscape-test-config-<port>/` directory
   - Launches with `--restore-channels` and `HOLOSCAPE_CONFIG_DIR=<dir>` from the *first* launch (previously `--restore-channels` was only appended after `cd`, which was too late — the current process still had the guard on and skipped saving)
3. Persistence tests sleep `1.5s` after `cd /tmp` before `restartApp()` so the debounced `saveState()` can flush.

## Known remaining failure (separate bug)

`DirectoryPersistenceUITests.testRestoredChannelStartsInSavedDirectory` —
passes the label restoration assertion (line 104) but fails at line 114 when
verifying cwd via `pwd` + `waitForAPIOutput`. After restart the restored
shell's terminal buffer is empty, not just missing the `pwd` output. This is a
distinct failure from the cd-label cluster and does not depend on the delegate
fix. Likely an interaction between `SwiftTerm.LocalProcessTerminalView`
activation ordering and `createChannelFromMetadata` (which calls `activate()`
before the controller is handed to the window controller). Tracking as a
separate investigation — do NOT re-label this as a delegate-fix regression.

## Next targets (not this PR)

1. `testRestoredChannelStartsInSavedDirectory` — investigate whether the
   restored channel's `terminalView.terminal` is nil or has no pty data,
   and whether the restore-path's `activate()` ordering is to blame.
2. Other Category D UI tests per `docs/round-9-all-failing-tests.md`.
