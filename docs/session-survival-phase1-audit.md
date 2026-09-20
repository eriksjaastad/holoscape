# Session Survival Phase 1 Audit (#7168)

Status: phase 1 is no longer blocked on the original process-survival substrate gaps. Recovery guidance is now surfaced in the UI and survives relaunch, and a live tab survives losing its broker. The umbrella stays open for the coordinator-path traps and recovery-hygiene items listed below.

## Acceptance gates checked

- Shell long-running process survives UI quit/relaunch shape: covered by `BrokerBackedTerminalProcessTests.testStartReattachesExistingBrokerSessionInsteadOfCreatingReplacement` and `ChannelManagerTests.testSavedBrokerBackedAgentRestoresAndReattachesAcrossManagerRelaunch` for detach/reattach semantics.
- Agent command session survives relaunch metadata: covered by `AppDelegateRestoredShellTests.testRestoredAgentUsesChannelManagerBrokerCoordinatorForExistingSession` and `ChannelManagerTests.testSavedBrokerBackedAgentRestoresAndReattachesAcrossManagerRelaunch`.
- UI crash/unmatched broker recovery: covered by `AppDelegateRestoredShellTests.testRestoreUnmatchedBrokerBackedSessionsAsTabsReattachesAndPersistsRecoveredShell`, `testRecoveredUnmatchedBrokerSessionDoesNotDuplicateAcrossRepeatedRelaunches`, and the ChannelManager unmatched-session tests.
- Resize, input after reattach, exit code, and scrollback tail: covered by `NativePTYBrokerSessionRuntimeTests` and `BrokerBackedTerminalProcessTests`.
- Missing broker / stale session behavior: covered by stale and broker-host-unavailable tests in `BrokerSessionCoordinatorTests`, `BrokerBackedTerminalProcessTests`, `ShellChannelControllerTests`, and `AgentChannelControllerTests`.
- Stale broker guidance stable across relaunch/restore: covered by `StaleBrokerRelaunchTests`, `ChannelManagerTests.testSaveStatePersistsStaleBrokerIdentityWithoutOfferingDeadSessionForReattach`, and the tab/sidebar guidance tests.
- Live tab survives the broker host disappearing underneath it (no trap; downgrade to retryable stale, handle preserved, no replacement): covered by the host-loss tests in `BrokerBackedTerminalProcessTests`, the live-downgrade tests in `ShellChannelControllerTests`/`AgentChannelControllerTests`, and `StaleBrokerRelaunchTests.testLiveTabThatLostBrokerHostKeepsRetryGuidanceAcrossRelaunchWithoutReplacement`.
- Coordinator-owned broker metadata transitions survive a broker outage (detach/exit/start no longer assert; the record keeps its reattachable lifecycle): covered by the `CoordinatorBackedBrokerFixture` tests in `ShellChannelControllerTests`, `AgentChannelControllerTests`, and `SSHChannelControllerTests`.
- An unreadable broker registry at launch no longer traps: the restore lookups report the read failure (`ChannelManager.brokerRegistryReadFailure`), keep the saved tabs and their persisted broker identity, and reattach the original session once the registry is readable again — covered by `ChannelManagerTests` unreadable-registry tests and `StaleBrokerRelaunchTests.testUnreadableBrokerRegistryKeepsSavedTabAndIdentityInsteadOfReplacingTheSession`.
- An unrecordable broker start leaves nothing behind: `BrokerSessionCoordinator.start` terminates the session it just created when the registry write fails and rethrows the registry failure, logging both errors (plus the session id) if the rollback itself fails — covered by `BrokerSessionCoordinatorTests.testStartTerminatesRuntimeSessionWhenRegistryWriteFails` and `testStartRollbackFailureStillSurfacesTheRegistryFailure`.
- Crash/unmatched recovery only surfaces live survivors: records the broker already marked stale are excluded (they are not crash survivors, and a saved tab that owns the identity still restores with recreate guidance) — covered by `ChannelManagerTests.testUnmatchedBrokerRecoverySkipsStaleRecordsAndKeepsLiveOnes`.

## Remaining focused slices before closing umbrella

- A launch against an unreadable registry still activates broker-backed tabs, so each such tab attempts a start that is now rolled back. Skipping the doomed attempt entirely would need a restore-path decision (and is a UX choice), not a coordinator fix.
- Stale broker records are retained in the registry until the owning tab recreates or exits; nothing prunes records that no tab will ever claim. Pruning needs a policy decision (age/ownership) rather than a recovery-path change.

## Non-goals still deferred

- #7169 maps richer broker lifecycle + agent status into persistent tab truth.
- #7171 owns durable scrollback/history beyond broker tail preservation.
- #7166 owns terminal correctness parity audit.
