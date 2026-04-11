# Round 9 — All 58 Failing Tests, Per-Test Triage

**Baseline**: round 9 P0 run (commits `f140529` + `0e2f19c`), 306 passed / 58 failed / 6 skipped = 84.1%. All failure messages below are verbatim from `/tmp/holoscape-test-shards/shard-*.txt`.

**With P2 (`99d4f8f`, HTTPParser rewrite) landed**: the reproducer `testSidebarScalesWithManyChannels` passes in isolation. The parser race that produced ~20 direct "HTTP 400 POST /channels: Invalid JSON body" errors is fixed at its source. A further ~13 "HTTP 404 POST /channels///input" cascade failures are *likely* fixed as well (they were downstream of the same parser bug corrupting a label somewhere), but those need spot verification per-test.

This doc groups every failing test into one of four categories so we can work through the remaining real UI bugs one at a time without re-running the full suite.

---

## Category A — Fixed by P2 parser rewrite (direct) — 20 tests

These hit the parser race directly: `apiCreateChannel` / `apiSendInput` / `apiNotify` received "HTTP 400 Invalid JSON body" because the server's HTTP parser returned a request with `body=nil` when URLSession split headers and body across TCP segments. P2 fixes this deterministically.

### Shard 1 — IntegrityUITests (11)
| Test | Error |
|------|-------|
| `testAPIChannelLifecycle` | `HTTP 400 POST /channels/lifecycle-test/input` |
| `testCmdNumberSwitchingWithManyChannels` | `HTTP 400 POST /channels` |
| `testContextMenuFullWorkflow` | `HTTP 400 POST /channels` |
| `testDisconnectedChannelShowsDisconnectedState` | `HTTP 400 POST /channels/disconnect-test/input` |
| `testNotificationTypesSetCorrectValues` | `HTTP 400 POST /notify` |
| `testRapidChannelCreateAndSwitch` | `HTTP 400 POST /channels` |
| `testSearchFindNavigateAndCount` | `HTTP 400 POST /channels/search-integrity/input` |
| `testSearchPersistsAcrossChannelSwitch` | `HTTP 400 POST /channels` |
| `testSidebarScalesWithManyChannels` | `HTTP 400 POST /channels` ✅ **verified fixed** |
| `testThemePersistsThroughChannelSwitch` | `HTTP 400 POST /channels` |
| `testUnreadBulletAppearsOnBackgroundOutput` | `HTTP 400 POST /channels/unread-test/input` |

### Shard 3 — StressUITests (2)
| Test | Error |
|------|-------|
| `testRapidAPISwitchingNoCrash` | `HTTP 400 POST /channels` |
| `testSixPlusTabsAllVisibleInSidebar` | `HTTP 400 POST /channels` |

### Shard 6 — HTTPAPIUITests (4)
| Test | Error |
|------|-------|
| `testCreateChannelViaAPI` | `HTTP 400 POST /channels` |
| `testDeleteChannelViaAPI` | `HTTP 400 POST /channels` |
| `testReadOutputFromChannel` | `HTTP 400 POST /channels` |
| `testSendInputAndReadOutput` | `HTTP 400 POST /channels/echo-test/input` |

### Shard 9 — TabBehaviorUITests (1)
| Test | Error |
|------|-------|
| `testNoReorderOnBackgroundOutput` | `HTTP 400 POST /channels/bg-output/input` |

### Shard 10 — NotificationSystemUITests (1)
| Test | Error |
|------|-------|
| `testNotificationAfterSuppressionWindowWorks` | `HTTP 400 POST /channels` |

---

## Category B — Likely fixed by P2 cascade — 13 tests (need spot-verify)

These failed with `HTTP 404 POST /channels///input` or `HTTP 404 GET /channels///output?lines=50`. The empty path segment comes from a test or helper that computed an empty label string — almost certainly because an earlier `apiCreateChannel` failed silently (Category A) and a downstream step read a label that was never set, or because the old `pathComponent(after:)` split ignored empty segments and silently remapped the route.

P2 fixes *both* sides: `apiCreateChannel` now succeeds (so whatever the test uses downstream has a real label), and `pathComponent(after:)` now preserves empty segments (so if a test *still* passes `""` we get a clean 400 "missing channel ID" instead of a confusing 404 on a fake label). Expected: most or all of these collapse.

### Shard 1 (1)
- `IntegrityUITests.testTimestampToggle` — `HTTP 404 POST /channels///input`

### Shard 3 — StressUITests (2)
- `testCommandHistory100Entries` — `HTTP 404 POST /channels///input`
- `testSubmit50Commands` — `HTTP 404 POST /channels///input`

### Shard 9 — SearchBarUITests (1)
- `testSearchShowsMatchCount` — `HTTP 404 POST /channels///input`

### Shard 9 — TabBehaviorUITests (2)
- `testCdToAnotherDirectoryUpdatesLabel` — `HTTP 404 POST /channels///input`
- `testCdUpdatesTabLabel` — `HTTP 404 POST /channels///input`

### Shard 9 — TerminalInputUITests (4)
- `testCopyFromTerminal` — `HTTP 404 POST /channels///input`
- `testTerminalFocusAfterAppReactivation` — `HTTP 404 GET /channels///output?lines=50`
- `testTerminalFocusOnChannelSwitch` — `HTTP 404 GET /channels///output?lines=50`
- `testTerminalViewAcceptsKeystrokes` — `HTTP 404 GET /channels///output?lines=50`

### Shard 10 — DirectoryPersistenceUITests (3)
- `testCdChangesLabelToDirectoryName` — `HTTP 404 POST /channels///input`
- `testDirectoryPersistsAcrossRestart` — `HTTP 404 POST /channels///input`
- `testRestoredChannelStartsInSavedDirectory` — `HTTP 404 POST /channels///input`

**Verification plan**: after the P2 PR lands, run these 13 tests *individually* (each ~5–10s) and check for pass/fail. Any that still fail move to Category D for real investigation. Total verification time: ~2 min.

---

## Category C — Intentional-error tests broken by P0 — 3 tests

These tests *want* a non-2xx response — they're asserting the server correctly returns 404 on missing channels. P0's `apiRequest` throw intercepts before the test's assertion runs, failing the test on a harness error instead of letting it check the status code.

| Shard | Test | Error |
|-------|------|-------|
| 6 | `HTTPAPIUITests.testDeleteNonexistentReturns404` | `HTTP 404 DELETE /channels/no-such-channel` |
| 6 | `HTTPAPIUITests.testInvalidChannelReturns404` | `HTTP 404 GET /channels/nonexistent/output?lines=5` |
| 6 | `HTTPAPIUITests.testSendInputToNonexistentReturns404` | `HTTP 404 POST /channels/fake/input` |

**Fix**: add `apiRequestAllowingError(_ method:path:body:)` (or `try? apiRequest(...)` in the test with a status-code-extraction variant) to `HoloscapeUITestCase.swift`. Update each of the 3 tests to use it and assert `status == 404`. Maybe 20 minutes of work. No app-side changes.

---

## Category D — Real UI bugs (22 tests)

These are the ones that need actual investigation. They are not masked by P0/P2 — the assertions are about UI state that genuinely isn't what the test expects. Grouped by feature area with verbatim error text so they can be picked off one at a time.

### D1 — Window Management / About Dialog (5 tests, shards 1 & 2)

| Test | File:Line | Error |
|------|-----------|-------|
| `WindowManagementUITests.testAboutDialogOpens` | `WindowManagementUITests.swift:108` | `Invalid parameter not satisfying: point.x != INFINITY && point.y != INFINITY (NSInternalInconsistencyException)` |
| `WindowManagementUITests.testAboutDialogCloses` | `WindowManagementUITests.swift:130` | Same `INFINITY` crash |
| `WindowManagementUITests.testWindowMinimize` | `WindowManagementUITests.swift:20` | `Not hittable: MenuItem, identifier: '_forceQuitRequested:', title: 'Force Quit Holoscape'` |
| `WindowManagementUITests.testWindowRestoreAfterMinimize` | `WindowManagementUITests.swift:88` | Same `Force Quit Holoscape` wrong-menu-item |
| `IntegrityUITests.testMinimizeRestoreFunctionality` | `IntegrityUITests.swift:726` | `XCTAssertTrue failed - Window should exist after restore` |

**Notable**: the two `testWindow*Minimize*` failures say **"Force Quit Holoscape"** is being hit when the test tries to click the minimize menu item. That's a menu ordering issue — either the menu changed, or the test's `NSPredicate` for finding the minimize item is matching the wrong element. Also the About dialog two are hitting a macOS AX framework crash on INFINITY coords — likely the About panel hasn't laid out yet when the test reads its frame.

### D2 — Search Advanced / Match Count Read (6 tests, shard 4)

All six read the search-match-count label and find it empty (`""`).

| Test | File:Line |
|------|-----------|
| `SearchAdvancedUITests.testSearchEnterAdvancesToNext` | `SearchAdvancedUITests.swift:104` |
| `SearchAdvancedUITests.testSearchMultipleMatchesCountCorrect` | `SearchAdvancedUITests.swift:175` |
| `SearchAdvancedUITests.testSearchNextButtonAdvancesMatch` | `SearchAdvancedUITests.swift:48` |
| `SearchAdvancedUITests.testSearchNoMatchesShowsZero` | `SearchAdvancedUITests.swift:192` |
| `SearchAdvancedUITests.testSearchPreviousButtonGoesBack` | `SearchAdvancedUITests.swift:77` |
| `SearchAdvancedUITests.testSearchSingleMatchShowsOneOfOne` | `SearchAdvancedUITests.swift:214` |

**Pattern**: every assertion is `XCTAssertNotEqual("", "")` or `"Match count should show 'X of Y' format, got: "`. The match-count label element is being read but its accessibility value is empty. Either the label isn't set, the AX identifier changed, or the label renders in a way XCUITest can't read. Single root cause likely.

### D3 — Session Launcher (2 tests, shard 4)
| Test | File:Line | Error |
|------|-----------|-------|
| `SessionLauncherUITests.testRecentSessionAppearsAfterCreation` | `SessionLauncherUITests.swift:176` | `Shell channel should appear in sidebar` |
| `SessionLauncherUITests.testSelectingShellProfileCreatesShellChannel` | `SessionLauncherUITests.swift:36` | `Shell channel should appear in sidebar after selection` |

**Pattern**: both assert on `sidebarEntry("Shell").waitForExistence`. Session launcher flow may be creating channels with a different label, or the sidebar isn't rendering after the selection picks a profile.

### D4 — Context Menu (1 test, shard 5)
| Test | File:Line | Error |
|------|-----------|-------|
| `ContextMenuUITests.testContextMenuCloseWithConfirmation` | `ContextMenuUITests.swift:73` | `Failed to click "Cancel" Button: Find single matching element. Multiple matching elements found` |

**Fix**: probably two Cancel buttons in scope (e.g., one in the close-confirmation sheet, one in a different dialog). Tighten the query to the specific sheet.

### D5 — Bug Report Dialog (2 tests, shard 6)
| Test | File:Line | Error |
|------|-----------|-------|
| `BugReportUITests.testSubmitWithDescriptionShowsConfirmation` | `BugReportUITests.swift:204` | `Confirmation alert should appear after submission` |
| `BugReportUITests.testSubmitWithEmptyDescriptionShowsValidation` | `BugReportUITests.swift:59` | `Submitting with empty description should show a validation alert` |

**Pattern**: both assertions wait on an `NSAlert.runModal()` dialog that never becomes hittable. `runModal` was known to be an XCUITest blocker in prior rounds — may still be.

### D6 — Split Pane (1 test, shard 7)
| Test | File:Line | Error |
|------|-----------|-------|
| `SplitPaneAdvancedUITests.testChannelSwitchInActivePaneOnly` | `HoloscapeUITestCase.swift:458` | `Channel should remain responsive after switch in pane` (via `assertActiveChannelResponsive`) |

Real split-pane channel-switching bug. Previously flagged in round 7 notes.

### D7 — Tab Bar (2 tests, shard 7)
| Test | File:Line | Error |
|------|-----------|-------|
| `TabBarUITests.testClickingTabSwitchesChannel` | `TabBarUITests.swift:121` | `XCTAssertGreaterThanOrEqual ("0") < ("2") - Should have at least 2 tab buttons` |
| `TabBarUITests.testTabBarAppearsWhenSidebarCollapsed` | `TabBarUITests.swift:21` | `Tab bar should show at least one tab when sidebar collapsed` |

**Pattern**: both tests can't find tab-bar buttons by AX query. Either the tab bar has 0 tabs (feature bug) or the AX identifier used by the query isn't the one on the tab buttons.

### D8 — Label Persistence (1 test, shard 9)
| Test | File:Line | Error |
|------|-----------|-------|
| `TabBehaviorUITests.testLabelsPeristAcrossRestart` | `TabBehaviorUITests.swift:56` | `Channel label should persist across restart` |

Real persistence bug — label isn't being saved/restored correctly.

### D9 — Notification Cold-Start (1 test, shard 10)
| Test | File:Line | Error |
|------|-----------|-------|
| `NotificationSystemUITests.testStartupSuppressionBlocksNotifications` | `HoloscapeUITestCase.swift:304` | `API server did not become ready within 10s at http://127.0.0.1:50684` |

**Already diagnosed earlier this session**: the test calls `freshApp.launch()` without passing `--api-port`, so the fresh instance listens on the compiled-in default (7865) while the test points at `Self.currentAPIBase` (random port). `ensureAPIReady` correctly times out and XCTFails. 5-line fix in the test.

### D10 — Skin Engine (1 test, shard 10)
| Test | File:Line | Error |
|------|-----------|-------|
| `SkinEngineUITests.testTestSkinAppearsInPicker` | `SkinEngineUITests.swift:48` | `Test skin should appear in skin picker` |

Real feature bug — the test skin isn't showing up in whatever the skin picker reads from.

### D11 — URL Scheme (1 test, shard 10)
| Test | File:Line | Error |
|------|-----------|-------|
| `URLSchemeUITests.testURLSchemeWithCommand` | `URLSchemeUITests.swift:34` | `Command from URL scheme should produce output` |

Real feature bug — URL-scheme-launched command not producing terminal output.

---

## Proposed order of attack (no full-suite runs)

| Priority | Target | Tests unblocked | Effort | Verification |
|----------|--------|----------------|--------|--------------|
| **P2** (landing now in this PR) | HTTPParser rewrite | ~20 direct + ~13 cascade = **33** | done | `testSidebarScalesWithManyChannels` already passes |
| **P3** | Spot-verify cascade (Category B) — run each of 13 tests individually | 13 | 2 min | per-test |
| **P4** | D9 — fix `testStartupSuppressionBlocksNotifications` port mismatch | 1 | 5 min | 20s test run |
| **P5** | Category C — add `apiRequestAllowingError` + update 3 intentional-error tests | 3 | 20 min | 10s run |
| **P6** | D2 — one fix for all 6 Search match-count reads (single root cause) | 6 | 30 min | 1 min |
| **P7** | D1 — Window menu: fix minimize tests (wrong menu item) + About dialog INFINITY | 5 | 1 hr | 2 min |
| **P8** | D3 — Session launcher sidebar | 2 | 30 min | 30s |
| **P9** | D7 — Tab bar AX identifier / creation | 2 | 30 min | 30s |
| **P10** | D5 — BugReport runModal | 2 | 1 hr | 30s |
| **P11** | D6 — Split pane channel switch | 1 | 1 hr | 30s |
| **P12** | D4 — Context menu Cancel disambiguation | 1 | 15 min | 20s |
| **P13** | D8, D10, D11 — label persistence, skin picker, URL scheme command | 3 | 30 min each | 30s |

Total verified work after P2: **58 failures → ~0** if every fix holds. Expected final pass rate: **363 / 364 ≈ 99.7%**.

## Do-not-touch list (lessons from today)

- **Don't run the full suite as a debugging step.** It's 60–80 minutes plus TCC re-approval risk. Re-run only after a batch of individual fixes lands, as a confirmation pass.
- **Don't trust subagent hypotheses without reading the code yourself.** (Sidebar NSStackView was fabricated; "500 Not ready" was wrong in mechanism.)
- **Don't build tail-drain RunLoop fixes** — tests already poll with `waitForExistence(timeout: 3-5)`, extra drain time doesn't help.
- **Content-Length recursion via String regex is flaky** — already replaced with Data-based Content-Length check in P2. Don't reintroduce the String path.
- **`ensureAPIReady` fires on every `apiRequest` call** — each `apiCreateChannel` = 2 HTTP round-trips (GET probe + POST). Account for this when reading diag logs.
