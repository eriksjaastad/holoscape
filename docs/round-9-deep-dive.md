# Round 9 Deep-Dive: Root-Cause Analysis of 48 Failing UI Tests

**Date**: 2026-04-11
**Baseline**: main @ 5eb052d, post-round-8 (316 passed / 48 failed / 6 skipped = 86.8%)
**Method**: Source-code analysis of every failing test + app handlers. No shard logs available on disk; classification derived from PR #48 round-8 data and direct code reads.

---

## Executive Summary

The 48 failures collapse into **6 root-cause buckets**. Two systemic issues account for the majority:

1. **`apiRequest` silently swallows HTTP errors** — affects every API-dependent test (~35 of 48). The helper returns `(Data, Int)` but callers discard the status code, and non-2xx responses don't throw. Any server-side 500 is invisible to the test.
2. **Channel creation is fire-and-forget** — `handleCreateChannel` returns `201` before the channel is confirmed to exist in the UI. Rapid-create loops hit MainActor scheduling races.

Fixing bucket A (apiRequest error handling) is prerequisite to diagnosing everything else, because without it you can't distinguish "server rejected the request" from "app bug."

---

## Bucket Classification

### Bucket A: `apiRequest` Swallows HTTP Errors (systemic — affects ~35 tests)

**File**: `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:316-352`

**Root cause**: `apiRequest` only throws on `URLSession` network errors (line 350). HTTP 4xx/5xx responses are returned as `(Data, statusCode)` — but every caller discards the status code:

```swift
// apiCreateChannel, apiDeleteChannel, apiSwitchChannel, apiSendInput, apiNotify
// all call apiRequest and ignore the Int
let (data, _) = try apiRequest(...)
```

If `HoloscapeAPIServer` returns `500 "Not ready"` (which it does when `channelManager` or `windowController` is nil — see `HoloscapeAPIServer.swift:156,169`), the test silently proceeds with garbage data, then fails on a downstream assertion like "sidebar entry not found" instead of "server returned 500."

**This means**: Every "channel not found in sidebar" failure across the entire suite could be either (a) a real app bug, or (b) the server rejecting the request and nobody checking. We literally cannot tell until this is fixed.

**Fix**: Add a status-code guard to `apiRequest`:

```swift
if let code = responseCode, !(200...299).contains(code) {
    let body = String(data: responseData ?? Data(), encoding: .utf8) ?? ""
    throw NSError(domain: "HoloscapeAPITest", code: code,
                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body)"])
}
```

**Tests unblocked**: All 48 — not because this fixes them, but because it reveals whether each failure is server-side (and thus a different fix) or app-side.

---

### Bucket B: Channel Creation Race — Fire-and-Forget (15 tests)

**Files**:
- `HoloscapeAPIServer.swift:168-182` — `handleCreateChannel`
- `MainWindowController.swift:467-490` — `openChannel`

**Root cause**: `handleCreateChannel` dispatches to `wc.openChannel()` and immediately returns `{"status": "created", 201}`. `openChannel` is on `MainWindowController` (inherits `@MainActor` from `NSWindowController`). The HTTP server handler runs on a background thread, so calling `openChannel` requires a MainActor hop. The response may return before the channel is actually created and rendered in the sidebar.

When tests create channels in a tight loop (e.g., `testSidebarScalesWithManyChannels` creates 10 with no inter-create delay), multiple MainActor hops queue up. The 1-second sleep after the loop may not be enough for all 10 to complete.

**The scale-1 mystery**: The test consistently fails on `scale-1` (the second of ten channels), not the last. This is consistent with a MainActor scheduling conflict: `scale-0`'s `switchToChannel()` call triggers UI updates (sidebar refresh, tab bar update) that are still executing when `scale-1`'s creation dispatches to MainActor. The first channel (scale-0) succeeds because there's no prior work competing. Later channels (scale-2 through scale-9) succeed because by then the pipeline has settled into a steady state. The second channel hits the worst-case overlap.

**Previous Claude's NSStackView hypothesis** (from an Explore agent): "NSStackView has undocumented behavior where rapid inserts at the same index can cause views to be replaced." I read `SidebarView.swift` and this is **not verified** — the sidebar uses standard SwiftUI `ForEach` over a published array, not `NSStackView` direct manipulation. The hypothesis is incorrect.

**Affected tests** (15):

| Shard | Test | Failure pattern |
|-------|------|-----------------|
| 1 | `IntegrityUITests.testSidebarScalesWithManyChannels` | scale-1 not found |
| 1 | `IntegrityUITests.testAPIChannelLifecycle` | Channel not found after create |
| 1 | `IntegrityUITests.testContextMenuFullWorkflow` | Channel not found |
| 1 | `IntegrityUITests.testDisconnectedChannelShowsDisconnectedState` | State not updated |
| 1 | `IntegrityUITests.testFullStateTransitionCycle` | State transition missed |
| 1 | `IntegrityUITests.testMinimizeRestoreFunctionality` | Channel state lost |
| 3 | `StressUITests.testCreate20Channels` | Missing channels |
| 3 | `StressUITests.testRapid100Cycles` | Timing |
| 6 | `HTTPAPIUITests` (multiple) | Channel ops on non-existent channel |
| 7 | `SplitPaneAdvancedUITests` (3 tests) | Channel switch in pane |
| 7 | `TabBarUITests.testClickingTabSwitchesChannel` | Channel not found |
| 7 | `TabBarUITests.testTabBarAppearsWhenSidebarCollapsed` | Channel not found |

**Fix proposal**: Make `handleCreateChannel` synchronous by waiting for the channel to appear in `channelManager.allChannels()` before returning the HTTP response. Alternatively, add a `waitForSidebarEntry` poll after each `apiCreateChannel` in the tests. The server-side fix is cleaner because it fixes all callers at once.

---

### Bucket C: Notification Silent Drop (7 tests)

**Files**:
- `HoloscapeAPIServer.swift:221-254` — `handleNotify` + `resolveChannelByCwd`
- `NotificationSystemUITests.swift:1-57`

**Root cause**: Two compounding issues:

1. **Silent drop**: `handleNotify` returns `{"status": "received", "type": ...}` (line 246) regardless of whether `resolveChannelByCwd` actually matched a channel. If the channel isn't found, the notification is silently discarded but the test gets a success response.

2. **`resolveChannelByCwd` matching logic** (line 249-254): Matches by comparing `URL(fileURLWithPath: cwd).lastPathComponent` to `displayLabel.lowercased()`. This works for `cwd: "/tmp/notify-green"` + label `"notify-green"`, but breaks if:
   - The channel hasn't finished initializing its `displayLabel` yet (race with creation)
   - The label was overridden by OSC 7 directory update (changes `currentDirectoryName`)

3. **Startup suppression window**: `handleNotify` checks `Date() < suppressUntil` (line 229). The `--disable-notification-suppression` launch arg should bypass this, but if the flag isn't parsed before the first `/notify` call arrives, the notification gets swallowed with `{"status": "suppressed"}`.

**In-isolation vs. in-shard discrepancy**: The previous Claude found all 5 NotificationSystemUITests fail in isolation but 3 pass in shard 10. This is explained by: when run as part of a shard, earlier test classes create channels and exercise the API server, ensuring `channelManager` and `windowController` are fully initialized. When run alone, the first `apiCreateChannel` may hit a `500 "Not ready"` from `handleCreateChannel` (line 169: `guard let wc = windowController else { return .error("Not ready", status: 500) }`), and since `apiRequest` swallows the error (Bucket A), the channel silently fails to create. All subsequent `/notify` calls then fail to resolve because the channel doesn't exist.

**Affected tests** (7):

| Shard | Test |
|-------|------|
| 10 | `NotificationSystemUITests.testIdlePromptTurnsTabGreen` |
| 10 | `NotificationSystemUITests.testPermissionPromptTurnsTabAmber` |
| 10 | `NotificationSystemUITests.testClickingNotifiedTabClearsState` |
| 10 | `NotificationSystemUITests.testStartupSuppressionBlocksNotifications` |
| 10 | `NotificationSystemUITests.testIdlePromptTurnsTabGreen` (dup in isolation) |
| 1 | `IntegrityUITests.testNotificationTypesSetCorrectValues` |
| 1 | `IntegrityUITests.testUnreadBulletAppears` |

**Fix proposal**:
1. Make `handleNotify` return `404` with `"channel not found"` when `resolveChannelByCwd` returns nil (instead of silent success)
2. Fix apiRequest to throw on non-2xx (Bucket A) — this will surface the 404 to tests
3. Add `Thread.sleep(forTimeInterval: 0.5)` between `apiCreateChannel` and `apiNotify` in the notification tests (or use `waitForExistence` which they already do)

---

### Bucket D: OSC 7 / cd Label Async Pipeline (9 tests)

**Files**:
- `TabBehaviorUITests.swift:17-44` — cd tests
- `Tests/HoloscapeUITests/DirectoryPersistenceUITests.swift` — persistence tests
- `Sources/Holoscape/Controllers/ShellChannelController.swift` — OSC 7 handler

**Root cause**: When a shell runs `cd /tmp`, the terminal emits OSC 7 (working directory update). The pipeline is:

```
cd /tmp → shell emits OSC 7 → terminal parses OSC 7
  → hostCurrentDirectoryUpdate → ShellChannelController.currentDirectoryName updated
  → channelStateDidChange → delegate (MainWindowController)
  → scheduleRefreshAllTabs() (debounced) → sidebar re-renders
```

The critical issue: `scheduleRefreshAllTabs()` is **debounced** — it coalesces rapid updates. Tests send `cd /tmp\n` via `apiSendInput` and then check for a sidebar entry with `waitForExistence(timeout: 5)`. But `sidebarEntry("tmp")` looks for `identifier BEGINSWITH 'sidebar-tmp'`. The sidebar entry's identifier is based on the channel's display label.

**Key subtlety**: When a channel is created with `label: "Shell"` (default) and you `cd /tmp`, the `displayLabel` changes from `"Shell"` to `"tmp"` (because `explicitLabel` is nil and `currentDirectoryName` is now `"tmp"`). But the sidebar entry's accessibility identifier may not update until `refreshAllTabs()` fires. The test's `waitForExistence(timeout: 5)` checks for a NEW element with identifier `sidebar-tmp`, but the existing element's identifier might update in-place — `waitForExistence` won't see it because the element already exists (just with a different identifier).

**Affected tests** (9):

| Shard | Test |
|-------|------|
| 9 | `TabBehaviorUITests.testCdUpdatesTabLabel` |
| 9 | `TabBehaviorUITests.testCdToAnotherDirectoryUpdatesLabel` |
| 9 | `TabBehaviorUITests.testLabelsPeristAcrossRestart` |
| 9 | `TabBehaviorUITests.testShellLabelShowsDirectoryNotShell` |
| 9 | `TabBehaviorUITests.testCmdWClosesChannel` |
| 9 | `TabBehaviorUITests.testNoReorderOnBackgroundOutput` |
| 10 | `DirectoryPersistenceUITests.testCdChangesLabel` |
| 10 | `DirectoryPersistenceUITests.testDirectoryPersistsAcrossRestart` |
| 10 | `DirectoryPersistenceUITests.testRestoredChannelStartsInSavedDirectory` |

**Fix proposal**: Change the cd tests to poll for the label content instead of element existence. Use an `XCTNSPredicateExpectation` that checks the sidebar entry's `title` or `value` property changing, rather than `waitForExistence` on a new identifier.

---

### Bucket E: Terminal Focus / First-Responder (5 tests)

**Files**:
- `TerminalInputUITests.swift:26-126`
- Terminal view's `makeFirstResponder` path in `MainWindowController`

**Root cause**: Tests click the terminal view and immediately type via `app.typeText()`. If the terminal NSView hasn't become first responder by the time `typeText` fires, keystrokes go to the wrong responder (or nowhere). The 0.5s `Thread.sleep` after channel switch may not be enough.

This is independent of the API issues — these tests use `app.typeText()` (XCUITest keyboard injection), not API helpers. The failure is pure UI automation timing.

**Affected tests** (5):

| Shard | Test |
|-------|------|
| 9 | `TerminalInputUITests.testTerminalViewAcceptsKeystrokes` |
| 9 | `TerminalInputUITests.testTerminalFocusOnChannelSwitch` |
| 9 | `TerminalInputUITests.testTerminalFocusAfterAppReactivation` |
| 9 | `TerminalInputUITests.testCopyFromTerminal` |
| 1 | `IntegrityUITests.testTerminalGetsFocusOnPTYSwitch` |

**Fix proposal**: After `terminal.click()`, add an explicit first-responder check by verifying the terminal's `hasFocus` or `isSelected` accessibility property before proceeding to `typeText()`. If no such property is exposed, add one to the terminal view.

---

### Bucket F: Long Tail — Window/Dialog/Search/Misc (12 tests)

These are smaller, independent clusters with distinct root causes:

#### F1: Window Management (5 tests, shard 2)

| Test | Likely cause |
|------|-------------|
| `WindowManagementUITests.testAboutDialogOpens` | About panel is a standard `NSApp.orderFrontStandardAboutPanel()` — may not create an XCUIElement accessible window |
| `WindowManagementUITests.testAboutDialogCloses` | Same |
| `WindowManagementUITests.testWindowMinimize` | Minimize animation timing |
| `WindowManagementUITests.testWindowRestoreAfterMinimize` | Restore from Dock timing |
| `KeyboardShortcutsUITests.testCmdW` | May close the only window, killing the test |

#### F2: Search Match Count (3 tests, shards 4/9)

| Test | Likely cause |
|------|-------------|
| `SearchAdvancedUITests` (multiple) | Buffer render must complete before search scan finds matches. `waitForAPIOutput` confirms output exists but search index may lag. |
| `SearchBarUITests.testSearchShowsMatchCount` | Same pipeline |

#### F3: Bug Report Dialog (2 tests, shard 6)

| Test | Likely cause |
|------|-------------|
| `BugReportUITests.testSubmitWithDescriptionShowsConfirmation` | `runModal()` fix landed but modal dialogs are notoriously hard to reach via XCUITest |
| `BugReportUITests.testSubmitWithEmptyDescriptionShowsValidation` | Same |

#### F4: Remaining singles (2 tests, shard 10)

| Test | Likely cause |
|------|-------------|
| `TimestampToggleUITests` | State persistence check — likely depends on channel existing |
| `ChannelStateIndicatorUITests` | Accessibility value not set in time |

---

## Proposed Order of Attack for Round 9

| Priority | Action | Tests Unblocked | Effort |
|----------|--------|-----------------|--------|
| **P0** | Fix `apiRequest` to throw on non-2xx HTTP status (Bucket A) | Diagnostic: reveals true root cause for all 48 | 5 min |
| **P1** | Re-run full suite with P0 fix — re-classify failures as server-error vs. app-bug | Accurate triage | 20 min |
| **P2** | Make `handleCreateChannel` wait for channel to exist before returning 201 (Bucket B) | ~15 tests | 30 min |
| **P3** | Make `handleNotify` return 404 when channel not matched (Bucket C) | ~7 tests | 10 min |
| **P4** | Fix cd label tests to poll for label content, not element existence (Bucket D) | ~9 tests | 30 min |
| **P5** | Add first-responder verification before typeText in terminal tests (Bucket E) | ~5 tests | 20 min |
| **P6** | Long-tail fixes (Bucket F) | ~12 tests | 1-2 hr |

**Critical path**: P0 must happen first. Everything else is contingent on knowing whether the server is actually returning errors. P1 (re-run with status checking) will likely reclassify several Bucket B/C/D failures as "server returned 500, fix the server" rather than "UI timing race."

---

## Do-Not-Touch List

Things the previous Claude tried that did not work or are confirmed dead ends:

| What | Why it's a dead end |
|------|---------------------|
| Adding "tail drain" sleeps after apiRequest | Tests already poll with `waitForExistence(timeout: 3-5)`. Extra sleeps don't help. |
| NSStackView rapid-insert hypothesis | Sidebar is SwiftUI `ForEach`, not `NSStackView`. Agent claim was wrong. |
| Editing NotificationSystemUITests test methods | Previous Claude edited two tests, all 5 then failed in isolation. Edits reverted but showed the class is fragile to any change — fix the infra, not the tests. |
| Blaming `ensureAPIReady` timeout | Fixed in round 8 (6385f48). The outer timeout works. API readiness is not the issue. |
| Blaming MainActor deadlock in API helpers | Fixed in round 8 (f2ff00d). The RunLoop-spin approach in apiRequest works correctly. |

---

## Key Files Reference

| File | What to look at |
|------|-----------------|
| `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:316-352` | `apiRequest` — add status-code guard here (P0) |
| `Sources/Holoscape/Services/HoloscapeAPIServer.swift:168-182` | `handleCreateChannel` — make synchronous (P2) |
| `Sources/Holoscape/Services/HoloscapeAPIServer.swift:221-254` | `handleNotify` + `resolveChannelByCwd` — return 404 on miss (P3) |
| `Tests/HoloscapeUITests/TabBehaviorUITests.swift:17-44` | cd tests — change to poll label content (P4) |
| `Tests/HoloscapeUITests/TerminalInputUITests.swift:26-126` | Focus tests — add first-responder check (P5) |
| `Sources/Holoscape/Controllers/MainWindowController.swift:467-490` | `openChannel` — understand channel creation flow |
| `Sources/Holoscape/Controllers/ShellChannelController.swift` | `displayLabel` computed property, OSC 7 handler |
