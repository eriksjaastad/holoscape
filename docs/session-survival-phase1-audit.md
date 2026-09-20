# Session Survival Phase 1 Audit (#7168)

Status: **phase 1 is complete and recommended for close-out.** Every acceptance gate below has named, passing coverage; the coordinator-path traps and crash-recovery hygiene items that previously held the umbrella open are fixed and tested. What remains is a short list of product/UX/policy decisions (below), none of which is a coding gap.

Verification for this close-out: `swift test --filter 'StaleBrokerRelaunchTests|ChannelManagerTests|BrokerSessionCoordinatorTests|BrokerBackedTerminalProcessTests|ShellChannelControllerTests|AgentChannelControllerTests|SSHChannelControllerTests|AppDelegateRestoredShellTests'` → 168 tests, 0 failures; full `swift test` → 1100 tests, 0 failures.

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
- Teardown while the broker is unreachable: tab close or app termination does not trap, the record keeps its reattachable lifecycle, and the terminal keeps the handle the next launch reads — covered by `BrokerBackedTerminalProcessTests.testDetachFailureWithBrokerHostOutageKeepsRecordReattachable`.
- Saved-tab-only restore shape (no broker attach possible) is deliberate for `agentAPI` tabs awaiting a key and for tabs restored straight into `.stale`; both skip activation and stay recoverable through the existing guidance.

## Remaining items (decisions, not coding gaps)

- **Restore UX when the registry is unreadable**: a launch still activates broker-backed tabs, so each attempts a start that is rolled back (`#7377`). Skipping the attempt entirely would leave tabs restored unattached; that is a product choice, not a fix.
- **Stale-record retention policy**: stale records stay in the registry until the owning tab recreates or exits, and nothing prunes records no tab will ever claim. Pruning needs an age/ownership policy.
- **SSH scope boundary**: `SSHChannelController` keeps its `ssh` process in the UI process (SwiftTerm), so an SSH tab reconnects on relaunch instead of resuming, and its broker record is bookkeeping only. That is deliberate: a killed remote connection cannot be resumed. Routing SSH through the broker runtime so the *local* client survives quit would be a new feature, not a phase-1 gap.

## Non-goals still deferred

- #7169 maps richer broker lifecycle + agent status into persistent tab truth.
- #7171 owns durable scrollback/history beyond broker tail preservation.
- #7166 owns terminal correctness parity audit.

## Close-out recommendation

Close `#7168`. Every gate above is covered by a test that fails if the behavior regresses; the slices in this lane were developed RED-first, and the teardown gate's test was verified by temporarily reinstating the old `assertionFailure` and watching the test trap. The open items are decisions (`restore UX when the registry is unreadable`, stale-record retention policy, SSH scope) plus the deferred non-goals, and should be carded separately if they are wanted. None of them is required for the phase-1 claim: broker-backed shell/agent tabs survive UI quit, crash, broker-host outage, an unreadable registry, and an unrecordable start without trapping or silently losing sessions.
