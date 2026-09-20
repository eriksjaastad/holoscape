# Session Survival Phase 1 Audit (#7168)

Status: phase 1 is no longer blocked on the original process-survival substrate gaps, but the umbrella should stay open until the focused recovery-instructions slice and PR review land.

## Acceptance gates checked

- Shell long-running process survives UI quit/relaunch shape: covered by `BrokerBackedTerminalProcessTests.testStartReattachesExistingBrokerSessionInsteadOfCreatingReplacement` and `ChannelManagerTests.testSavedBrokerBackedAgentRestoresAndReattachesAcrossManagerRelaunch` for detach/reattach semantics.
- Agent command session survives relaunch metadata: covered by `AppDelegateRestoredShellTests.testRestoredAgentUsesChannelManagerBrokerCoordinatorForExistingSession` and `ChannelManagerTests.testSavedBrokerBackedAgentRestoresAndReattachesAcrossManagerRelaunch`.
- UI crash/unmatched broker recovery: covered by `AppDelegateRestoredShellTests.testRestoreUnmatchedBrokerBackedSessionsAsTabsReattachesAndPersistsRecoveredShell`, `testRecoveredUnmatchedBrokerSessionDoesNotDuplicateAcrossRepeatedRelaunches`, and the ChannelManager unmatched-session tests.
- Resize, input after reattach, exit code, and scrollback tail: covered by `NativePTYBrokerSessionRuntimeTests` and `BrokerBackedTerminalProcessTests`.
- Missing broker / stale session behavior: covered by stale and broker-host-unavailable tests in `BrokerSessionCoordinatorTests`, `BrokerBackedTerminalProcessTests`, `ShellChannelControllerTests`, and `AgentChannelControllerTests`.

## Remaining focused slice before closing umbrella

Make missing-broker recovery guidance explicit in UI surfaces so failure is actionable, not just typed internally. The first step is `ChannelRecoveryAction.operatorGuidance` plus context-menu tooltip coverage; follow-up should decide whether the same guidance belongs in the tab/sidebar stale-state visual surface or a modal/error banner.

## Non-goals still deferred

- #7169 maps richer broker lifecycle + agent status into persistent tab truth.
- #7171 owns durable scrollback/history beyond broker tail preservation.
- #7166 owns terminal correctness parity audit.
