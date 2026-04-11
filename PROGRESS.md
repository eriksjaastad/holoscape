# Session Progress — 2026-04-10 (round 7 full-suite run)

## Headline
- **297 passed / 73 failed / 6 skipped → 80.3% pass rate** (370 tests run)
- Baseline before round 6+7 fixes: 293/378 (78%)
- Net movement: **+4 passing**. The 73 remaining failures mostly fall into the same clusters as round 6, meaning the fixes landed in code but did not resolve the underlying runtime behavior.

## Round 6/7 fixes verified present on disk
All the following are on `main` and not reverted — they just don't resolve the failures at runtime:

| Fix | Location |
|---|---|
| `--api-port` launch arg wiring | `Sources/Holoscape/AppDelegate.swift:51-57` |
| Random per-test port (49152–60999) | `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:16-20` |
| `currentAPIBase` static for nonisolated helpers | `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:265` |
| `waitForAPIOutput` before search | `Tests/HoloscapeUITests/SearchAdvancedUITests.swift:13` |
| `searchMatchCountText(timeout: 5)` | `Tests/HoloscapeUITests/HoloscapeUITestCase.swift:250` |
| Window menu with Minimize + `NSApp.windowsMenu` | `Sources/Holoscape/AppDelegate.swift:354-360` |
| BugReport `alert.runModal()` | `Sources/Holoscape/Views/BugReportDialog.swift:212` |
| Context-menu `autoenablesItems = false` | `Sources/Holoscape/Controllers/MainWindowController.swift:774` |

Next session must **debug runtime behavior**, not re-apply the same fixes.

## Shard results (Xcode "Executed N tests")

| Shard | Classes | Run | Failed | Skipped |
|-------|---------|-----|--------|---------|
| 1 | IntegrityUITests | 41 | 14 | 0 |
| 2 | KeyboardShortcutsUITests, WindowManagementUITests | 34 | 5 | 0 |
| 3 | StressUITests, ThemeSwitchingUITests | 31 | 7 | 0 |
| 4 | SearchAdvancedUITests, SettingsUITests, SessionLauncherUITests | 44 | 8 | 3 |
| 5 | FontSettingsUITests, EditMenuUITests, ContextMenuUITests | 42 | 3 | 3 |
| 6 | BugReportUITests, HTTPAPIUITests, TransparencyColorWellUITests | 33 | 8 | 0 |
| 7 | HoloscapeUITests, TabBarUITests, SplitPaneAdvancedUITests, InputBoxUITests | 37 | 6 | 0 |
| 8 | ChannelOrderingUITests, AgentChannelUITests, SplitPaneUITests, CloseConfirmationUITests | 31 | 2 | 0 |
| 9 | BridgeChannelUITests, TerminalInputUITests, TabBehaviorUITests, SidebarUITests, SearchBarUITests | 31 | 11 | 0 |
| 10 | URLSchemeUITests, TerminalDisplayUITests, SSHChannelUITests, NotificationSystemUITests, TimestampToggleUITests, SkinEngineUITests, ConfigPersistenceUITests, ChannelStateIndicatorUITests, ChannelRestorationUITests, NotificationUITests, DirectoryPersistenceUITests | 46 | 9 | 0 |
| **Total** | | **370** | **73** | **6** |

Note: the shard script's grep-based summary is unreliable (counts "failed" substrings, not tests). Trust the Xcode "Executed" lines.

## Failure clusters — 73 tests

IntegrityUITests (shard 1) is a meta-suite that re-runs feature paths. Most of its failures shadow failures in feature-specific shards; fixing a cluster root cause should resolve the Integrity case for free.

| # | Cluster | Count | Shards | Failing tests | Root-cause hypothesis |
|---|---------|-------|--------|---------------|------------------------|
| A | **HTTP API** | 7 | 6, 1 | HTTPAPIUITests {CreateChannel, CreateChannelWithDirectory, DeleteChannel, ResolveByLabel, SendInputAndReadOutput, SwitchChannel}; Integrity.testAPIChannelLifecycle | Port-isolation fix wired but API still not reachable at expected port. Check test-server startup race / AppDelegate timing / whether HoloscapeAPIServer actually binds to the passed port. |
| B | **Search match count** | 9 | 4, 1, 9 | SearchAdvanced {EnterAdvancesToNext, MultipleMatches, Next/PreviousButton, NoMatches, SingleMatch}; Integrity.testSearchFindNavigateAndCount, testSearchPersistsAcrossChannelSwitch; SearchBar.testSearchShowsMatchCount | `waitForAPIOutput` helper present but matches still not counted. Buffer render vs. search scan ordering. |
| C | **cd/directory labels** | 9 | 9, 10 | TabBehavior {CdToAnotherDirectory, CdUpdatesTabLabel, LabelsPeristAcrossRestart, NoReorderOnBackgroundOutput, ShellLabelShowsDirectoryNotShell, CmdWClosesChannel}; DirectoryPersistence {CdChangesLabel, DirectoryPersistsAcrossRestart, RestoredChannelStartsInSavedDirectory} | OSC 7 → sidebar label pipeline. Likely single bug across cd-handler + restart restore. |
| D | **Stress / many channels** | 8 | 3, 1 | StressUITests {CommandHistory100Entries, Create20Channels, CtrlCKeepsTabOpen, ExitShowsDisconnected, Rapid100Cycles, SixPlusTabs, Submit50Commands}; Integrity.testSidebarScalesWithManyChannels | Rapid create/close timing; per-channel waits added last round may not cover all cases. |
| E | **Terminal focus/input** | 5 | 9, 1 | TerminalInput {CopyFromTerminal, FocusAfterAppReactivation, FocusOnChannelSwitch, AcceptsKeystrokes}; Integrity.testTerminalGetsFocusOnPTYSwitch | Focus handling after switch/reactivation; may be coupled to cluster A if helpers hit API. |
| F | **Notifications** | 7 | 10, 1 | NotificationSystem {ClickingNotifiedTab, IdlePromptAmber, PermissionAmber, StartupSuppression}; Integrity {testNotificationTypesSetCorrectValues, testUnreadBulletAppears, testSidebarUnreadBackgroundState} | Notification state machine regression. |
| G | **Context menu / Cmd+W close** | 6 | 5, 1, 7, 9, 8 | ContextMenu {CloseActiveChannelSwitches, CloseRemovesChannel, CloseWithConfirmation}; HoloscapeUITests.testCmdWClosesChannel; Integrity.testContextMenuFullWorkflow; TabBehavior.testCmdWClosesChannel; AgentChannel.testAgentChannelDeactivates; ChannelOrdering.testClosedChannelRemovedCleanly | Close-confirmation path. `autoenablesItems=false` landed but doesn't cover all entry points. |
| H | **Window / About / Minimize** | 5 | 2, 1 | Keyboard.testCmdW; WindowManagement {AboutDialogOpens, AboutDialogCloses, WindowMinimize, WindowRestoreAfterMinimize}; Integrity.testMinimizeRestoreFunctionality | Window menu added last round — verify About dialog + minimize interaction. |
| I | **Split pane** | 3 | 7 | SplitPaneAdvanced {ChannelSwitchInActivePaneOnly, ClosePaneAfterClosingChannel, ClosingChannelInSplitDoesNotCrash} | Small, self-contained. |
| J | **Tab bar** | 2 | 7 | TabBar {ClickingTabSwitchesChannel, TabBarAppearsWhenSidebarCollapsed} | Small. |
| K | **State transitions** | 3 | 1 | Integrity {testDisconnectedChannelShowsDisconnectedState, testFullStateTransitionCycle, testTimestampToggle, testThemePersistsThroughChannelSwitch} | Integrity-only; may resolve when A/F fixed. |
| L | **Session launcher** | 2 | 4 | SessionLauncher {RecentSessionAppearsAfterCreation, SelectingShellProfileCreatesShellChannel} | Small. |
| M | **Bug Report** | 2 | 6 | BugReport {SubmitWithDescriptionShowsConfirmation, SubmitWithEmptyDescriptionShowsValidation} | `runModal` fix landed; investigate why test still can't find alerts. |
| N | **Singles** | 2 | 10 | SkinEngine.testTestSkinAppearsInPicker; URLScheme.testURLSchemeWithCommand | Small. |

## Suggested parallel work split

Highest-leverage clusters for delegation to a cousin agent:
- **Cluster A (HTTP API, 7 tests)** — needs runtime debugging of why `--api-port` isn't making the server reachable. Instrument HoloscapeAPIServer init; verify test-side hits the right port; check for ordering bug where tests try API before server binds.
- **Cluster C (cd/directory labels, 9 tests)** — single likely root cause (OSC 7 + restore). Small blast radius, high payoff.
- **Cluster F (notifications, 7 tests)** — state-machine bug; may benefit from fresh eyes.

Leave for the primary session:
- **Cluster B (search, 9 tests)** — entangled with cluster A since search uses API helpers.
- **Cluster D (stress, 8 tests)** — timing-sensitive; historically flaky.

Backlog / opportunistic fixes:
- Clusters E, G, H, I, J, K, L, M, N — mostly small, self-contained, pick off as time allows.

## Open architectural questions
- Is `--api-port` actually taking effect? Need to log the actual bind port in `HoloscapeAPIServer` at startup and verify tests see that port in their requests.
- Should `HoloscapeAPIServer` expose a "ready" signal the tests can wait on, instead of the current poll-until-first-call pattern?
