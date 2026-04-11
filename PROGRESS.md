# Session Progress — Round 8 Results (2026-04-11)

## TL;DR

**Round 8: 316 passed / 48 failed / 6 skipped → 86.8%** (pass/(pass+fail))

Round 7 → Round 8: **80.3% → 86.8% (+6.5pt, +19 passing)**. The MainActor deadlock fix (`f2ff00d`) and the `ensureAPIReady` outer-timeout fix (`6385f48`, PR #47) both landed and produced real movement — but we underperformed the ~92% target. Three surprise failure pockets (Integrity, TerminalInput/TabBehavior, NotificationSystem) are the next targets.

## Full round 8 per-shard

| Shard | Classes | Tests | Fails | Skip |
|-------|---------|-------|-------|------|
| 1 | IntegrityUITests | 41 | **10** ❌ | 0 |
| 2 | KeyboardShortcuts, WindowManagement | 34 | 5 | 0 |
| 3 | Stress, ThemeSwitching | 31 | 2 | 0 |
| 4 | SearchAdvanced, Settings, SessionLauncher | 44 | 8 | 3 |
| 5 | FontSettings, EditMenu, ContextMenu | 42 | 1 | 3 |
| 6 | BugReport, HTTPAPI, TransparencyColorWell | 33 | 4 | 0 |
| 7 | Holoscape, TabBar, SplitPaneAdvanced, InputBox | 37 | 3 | 0 |
| 8 | ChannelOrdering, AgentChannel, SplitPane, CloseConfirmation | 31 | **0** ✅ | 0 |
| 9 | Bridge, TerminalInput, TabBehavior, Sidebar, SearchBar | 31 | **8** ❌ | 0 |
| 10 | URLScheme, TerminalDisplay, SSHChannel, NotificationSystem, TimestampToggle, SkinEngine, ConfigPersistence, ChannelStateIndicator, ChannelRestoration, Notification, DirectoryPersistence | 46 | 7 | 0 |
| **Total** | | **370** | **48** | **6** |

## Shard 10 per-class (for triage)

| Class | Tests | Fails |
|-------|-------|-------|
| URLSchemeUITests | 4 | 0 ✅ |
| TerminalDisplayUITests | 4 | 0 ✅ |
| SSHChannelUITests | 4 | 0 ✅ |
| **NotificationSystemUITests** | **3** | **3** ❌ (total wipeout) |
| TimestampToggleUITests | 5 | 2 |
| SkinEngineUITests | 3 | 0 ✅ |
| ConfigPersistenceUITests | 5 | 0 ✅ |
| ChannelStateIndicatorUITests | 4 | 1 |
| ChannelRestorationUITests | 5 | 0 ✅ |
| NotificationUITests | 4 | 0 ✅ |
| DirectoryPersistenceUITests | 5 | 1 |

## Shards/clusters the deadlock fix cleared (as predicted)

- **Shard 8**: 0 failures (ChannelOrdering/Agent/SplitPane/CloseConfirmation)
- **Shard 5**: 1 failure (FontSettings/EditMenu/ContextMenu — cluster G collapsed)
- **Shard 3**: 2 failures (Stress — cousin Claude's revised prediction nailed it)
- **Shard 6**: 4 failures (HTTPAPI cluster ≈ 0; BugReport still a problem)

## Three surprise failure pockets (round 8 → round 9 targets)

### 1. Shard 1 IntegrityUITests — 10 failures (predicted: low)

The full-suite integrity tests hit the API heavily. The deadlock fix should have cleared most of these. Either:
- A second, latent blocking point exists in the integrity harness; or
- The failures are real feature regressions around app launch/teardown that the deadlock was masking.

**Action**: dump all 10 failing test names + first failure messages from `/tmp/holoscape-test-shards/shard-1.txt`.

### 2. Shard 9 TerminalInput + TabBehavior — 8 failures (predicted: low)

Known failing from the rerun3 log tail:
- `TabBehaviorUITests.testCdToAnotherDirectoryUpdatesLabel`
- `TabBehaviorUITests.testCdUpdatesTabLabel`
- `TabBehaviorUITests.testLabelsPersistAcrossRestart`
- `TerminalInputUITests.testCopyFromTerminal`
- `TerminalInputUITests.testTerminalFocusAfterAppReactivation`
- `TerminalInputUITests.testTerminalFocusOnChannelSwitch`
- `TerminalInputUITests.testTerminalViewAcceptsKeystrokes`

Cluster C (cd/directory labels) was predicted 0–2 fails after the deadlock fix. Hitting 3 here is unexpected — same with terminal focus. Either `waitForAPIOutput` has its own deadlock variant or these are real bugs in cd/label handling and terminal focus tracking.

**Action**: pull actual failure messages from `shard-9.txt`.

### 3. NotificationSystemUITests — 3/3 total wipeout (predicted: 0–1)

A full-class failure is suspicious. Could be a single setUp-level failure cascading. Could be a missing @MainActor annotation. Could be a notification-permission prompt that never gets dismissed.

**Action**: pull the NotificationSystemUITests section from `shard-10.txt`, check for `setUp` or `tearDown` errors first.

## Other remaining failures to classify (35 across clusters)

- Shard 2 KeyboardShortcuts/WindowManagement (5) — likely real feature bugs
- Shard 4 Search/Settings/SessionLauncher (8) + 3 skipped — split pane / launcher clusters, predicted to stay
- Shard 6 BugReport/HTTPAPI/Transparency (4) — BugReport a11y query was flagged in PROGRESS
- Shard 7 Holoscape/TabBar/SplitPane/InputBox (3) — tab bar + split pane, predicted to stay
- Shard 10 TimestampToggle (2), ChannelStateIndicator (1), DirectoryPersistence (1)

## Known environmental issue

**TCC automation-mode grant is unstable across xcodebuild invocations.** Each `build-for-testing` triggers a `CodeSign ... replacing existing signature` step, which can invalidate the Accessibility/Automation grant for `HoloscapeUITests-Runner.app`. The first two shard-10 reruns failed with `Timed out while enabling automation mode` before any test could run; Erik had to click through the permission prompt manually for attempt 3 to work.

**Fix-later task**: investigate whether stable signing (maybe a persistent dev identity instead of "Sign to Run Locally") prevents TCC re-prompts on each fresh xcodebuild run.

## Environment notes

- Project: `/Users/eriksjaastad/holoscape`
- Branch: `main` at `5eb052d` (merge of PR #47)
- Shard results: `/tmp/holoscape-test-shards/shard-{1..10}.txt`
  - Note: shard-10.txt has been overwritten 3 times — current contents are the successful third attempt.
- Background logs: `/tmp/holoscape-tests/shards-all.log` (original run), `shard-10-rerun{,2,3}.log`
- Shard script: `./scripts/test-ui-shards.sh`
- PRs merged this session: #47 (fix/ui-tests-round8-api-ready-timeout)
