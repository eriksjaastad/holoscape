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

## Remaining focused slices before closing umbrella

- Coordinator-owning paths still assert on broker errors: `recordBrokerStart`/`recordBrokerDetach`/`recordBrokerExit` in `ShellChannelController`, `AgentChannelController`, and `SSHChannelController` call `assertionFailure` when the coordinator throws. Broker-backed shell/agent tabs inject no coordinator so they are unaffected, but SSH tabs and injected-coordinator channels can still trap if the host dies during detach/exit.
- Unmatched-broker recovery still treats `.stale` records as crash survivors: `ChannelManager.restoreUnmatchedBrokerBackedSessions` can surface a dead session as a "recovered" tab when no tab owns it.

## Non-goals still deferred

- #7169 maps richer broker lifecycle + agent status into persistent tab truth.
- #7171 owns durable scrollback/history beyond broker tail preservation.
- #7166 owns terminal correctness parity audit.
