# Terminal correctness audit against iTerm daily-driver behavior

Status: completed audit for Kanban card #7166.

## Scope

This audit focuses on terminal correctness surfaces that must feel iTerm-boring before Holoscape adds more feature breadth:

- local shell and OAuth agent PTY launch behavior;
- window resize propagation;
- current-directory truth;
- environment/terminal identity;
- output/input plumbing through the broker-backed terminal path;
- scrollback limits that affect relaunch context.

It does not attempt to prove the full AppKit UI suite, skin rendering, Project Tracker integration, or future plugin architecture.

## Evidence inspected

Code entry points:

- `Sources/Holoscape/Views/HoloscapeTerminalView.swift`
- `Sources/Holoscape/Protocols/TerminalProcess.swift`
- `Sources/Holoscape/Services/BrokerBackedTerminalProcess.swift`
- `Sources/Holoscape/Services/NativePTYBrokerSessionRuntime.swift`
- `Sources/Holoscape/Controllers/ShellChannelController.swift`
- `Sources/Holoscape/Controllers/AgentChannelController.swift`
- `Sources/Holoscape/Controllers/ChannelManager.swift`
- `Sources/Holoscape/Controllers/MainWindowController.swift`
- `Sources/Holoscape/Services/DefaultWorkingDirectory.swift`
- `Sources/Holoscape/Services/AuthEnvironmentBuilder.swift`

Existing tests reviewed:

- `Tests/HoloscapeTests/Unit/NativePTYBrokerSessionRuntimeTests.swift`
- `Tests/HoloscapeTests/Unit/BrokerBackedTerminalProcessTests.swift`
- `Tests/HoloscapeTests/Unit/SessionProfileManagerTests.swift`

## What is already solid enough to keep

### Broker-backed PTY sessions exercise real input/output

`NativePTYBrokerSessionRuntimeTests.testLocalPTYSessionAcceptsInputProducesOutputResizesAndTerminates` launches `/bin/cat`, sends input, reads output, resizes the runtime, terminates, and confirms scrollback retained the output. That is the right foundation: use real PTYs, not mocks, for correctness gates.

### OAuth agent environment is intentionally clean

`AuthEnvironmentBuilder` sets a narrow OAuth environment with `PATH`, `HOME`, `SHELL`, `TERM=xterm-256color`, and `LANG=en_US.UTF-8`, and does not leak `ANTHROPIC_API_KEY`. `NativePTYBrokerSessionRuntimeTests.testAgentOAuthProfileUsesCleanEnvironmentWithoutAPIKeyLeakage` covers this.

### Broker failures now have explicit tab-level recovery states

`BrokerBackedTerminalProcess` classifies broker-host outages and stale broker sessions instead of silently replacing sessions. The #7168 work should stay intact; the correctness fixes below should not weaken fail-closed recovery semantics.

## Correctness gaps vs iTerm daily-driver behavior

### 1. Broker-backed tabs do not propagate live view resize into the child PTY

**Current behavior from code:**

- `NativePTYBrokerSessionRuntime.resizeSession(id:size:)` can call `ioctl(TIOCSWINSZ)`.
- `BrokerBackedTerminalProcess.resizeToCurrentGrid()` can forward the current grid size.
- But `TerminalProcess` does not expose resize, and `ShellChannelController.sizeChanged(...)` currently says SwiftTerm handles resize internally.
- In the broker-backed path, SwiftTerm no longer owns the child process, so SwiftTerm cannot resize that process for us.

**Why iTerm users notice:** fullscreen/split-pane changes, font-size changes, and window resizing should immediately update `stty size`, full-screen TUIs, editors, pagers, and shells using `$COLUMNS/$LINES`.

**Reproduction target:**

1. Open a broker-backed shell in Holoscape.
2. Run `watch -n 0.2 'stty size'` or `python3 -c 'import os,pty; print(os.get_terminal_size())'` repeatedly.
3. Resize the Holoscape window or sidebar/split pane.
4. Expected iTerm behavior: row/column values change immediately.
5. Suspected Holoscape behavior: the SwiftTerm view changes, but the child PTY stays at the launch size.

**Test target:** add a unit test around `ShellChannelController.sizeChanged` or a protocol-level resize hook proving a resize event calls `BrokerSessionRuntime.resizeSession` with the new `TerminalGridSize`. Keep the runtime-level PTY resize test as the lower-level gate.

**Next slice:** implement `TerminalProcess.resizeToCurrentGrid()` in the protocol, forward from channel controllers' `sizeChanged`, and add a fake runtime/coordinator assertion test.

### 2. Broker-backed shell current-directory truth is weaker than iTerm/Apple Terminal

**Current behavior from code:**

- `ShellChannelController` sets `processDelegate` only when `terminal as? LocalProcessTerminalView` succeeds.
- The broker-backed terminal is a `BrokerBackedTerminalProcess`, not a `LocalProcessTerminalView`, even though it owns a `HoloscapeTerminalView` internally.
- Therefore `hostCurrentDirectoryUpdate(source:directory:)` is not wired through the broker-backed shell path.
- The fallback `ShellDirectoryTracker.consume(data:)` only sees user input and cannot reliably detect `cd` inside scripts, aliases, `pushd/popd`, shell startup changes, or external OSC 7 updates.

**Why iTerm users notice:** tab labels, restored working directories, new shells, and notification context should track the actual shell cwd, not merely the last typed `cd`-looking input.

**Reproduction target:**

1. Open a broker-backed shell in Holoscape.
2. Run `cd ~/projects/holoscape-agent` and confirm the tab label changes.
3. Run `python3 - <<'PY'\nimport os\nos.chdir('/')\nPY` or source a script that changes directories through shell functions/aliases.
4. Compare with iTerm/Apple Terminal cwd title behavior and Holoscape persisted `workingDirectory` after relaunch.

**Test target:** create a broker-backed terminal fixture whose internal terminal view receives an OSC 7 directory update, then assert `ShellChannelController.workingDirectory` and display label update. If direct SwiftTerm OSC 7 driving is awkward, first add a narrow seam on `TerminalProcess` for host-directory callbacks and test that seam.

**Next slice:** expose host-directory callbacks from `BrokerBackedTerminalProcess`/`HoloscapeTerminalView` to channel controllers; stop relying on the typed-input tracker as the primary truth source.

### 3. URL-scheme agent channels still default to home, not the preferred projects root

**Current behavior from code:**

- New Channel → Agent uses `DefaultWorkingDirectory.preferredURL`.
- Session profile `Claude` also resolves to `DefaultWorkingDirectory.preferredPath`.
- But `MainWindowController.openChannel(type: "agent", directory: nil, ...)` uses `URL(fileURLWithPath: NSHomeDirectory())`.

**Why iTerm users notice:** agent channels created through automation/deep links should land in the same predictable default as the manual launcher. The card #5868 symptom says agent channels open in the wrong place before running Claude.

**Reproduction target:**

1. Invoke the `holoscape://` URL path for an agent without a directory.
2. Check the first shell/agent cwd visible to Claude.
3. Expected: `~/projects` when it exists.
4. Current code path: home directory.

**Test target:** a `MainWindowController.openChannel(type: "agent", directory: nil, ...)` unit/UI harness is probably heavy; a smaller first test can extract default-directory resolution for URL-created agents into a pure helper and assert it returns `DefaultWorkingDirectory.preferredURL`.

**Next slice:** make URL-created agent channels use `DefaultWorkingDirectory.preferredURL` when `directory` is nil, then verify #5868 manually and with a focused test.

### 4. Shell profile does not explicitly guarantee `TERM=xterm-256color`

**Current behavior from code:**

- `NativePTYBrokerSessionRuntime.environment(for: .shell)` inherits the UI process environment and only forces `TERM_PROGRAM=Apple_Terminal`.
- OAuth agents get `TERM=xterm-256color`, but shells do not have an equivalent explicit guarantee.

**Why iTerm users notice:** CLI color behavior, curses apps, and shell startup scripts often branch on `TERM`. GUI-launched apps can have a thinner environment than an interactive terminal.

**Reproduction target:**

1. Launch Holoscape as a GUI app, not from an existing terminal.
2. Run `printf '%s\n' "$TERM" "$TERM_PROGRAM" "$LANG"` in a shell channel.
3. Expected iTerm-like baseline: `TERM=xterm-256color`, UTF-8 locale, Apple-compatible directory notifications.

**Test target:** extend `NativePTYBrokerSessionRuntimeTests.testShellProfilePreservesAppleTerminalDirectoryUpdateCompatibility` to also require `TERM=xterm-256color` and `LANG` presence, after deciding the exact values.

**Next slice:** set explicit terminal identity for shell profiles while preserving OSC 7 compatibility.

### 5. PTY interactive smoke coverage is partially proven

**Current behavior from code:**

- `NativePTYBrokerSessionRuntime` uses `openpty`, wires the slave file handle to `Process.standardInput/Output/Error`, and launches the process.
- Runtime tests now prove broker-owned sessions are not plain pipes: `tty` reports a `/dev/tty*` device and does not report `not a tty`.
- Runtime tests also prove `stty size` sees both the initial requested grid and a later broker resize.

**Why iTerm users notice:** job control, signals, full-screen programs, password prompts, shells with `set -m`, and tools like `vim`, `less`, `ssh`, `sudo`, and agent CLIs depend on real terminal semantics beyond byte echo.

**Reproduction target:**

1. In Holoscape, run `tty`, `stty -a`, `vim`, `less`, `ssh`, and a Ctrl-C/Ctrl-Z job-control sequence.
2. Compare behavior with iTerm.

**Remaining test target:** add signal/job-control coverage only when it is deterministic under headless XCTest. The stable smoke layer now covers TTY identity and grid sizing.

**Next slice:** keep signal/job-control and full-screen TUI behavior as a manual/app-hosted smoke target unless a stable unit harness emerges.

### 6. Scrollback recovery is capped at audit-only levels, not daily-driver levels

**Current behavior from code:**

- Runtime scrollback buffer cap is `1_048_576` bytes per session.
- Reattach feeds only `65_536` bytes into the terminal view.

**Why iTerm users notice:** relaunch should restore enough context to understand the current agent/shell state. A 64 KiB visible tail may be okay for #7168, but not enough for #7171/#5884 daily-driver history.

**Reproduction target:**

1. Print more than 64 KiB of structured output in a tab.
2. Quit/relaunch Holoscape and reattach.
3. Compare restored context with iTerm's scrollback expectations.

**Test target:** keep #7168 tests at survival scope, then add #7171 tests for storage limit policy, redaction/privacy rules, corruption handling, and user-visible restore amount.

**Next slice:** leave this to #7171/#5884; do not silently inflate buffers without a storage/privacy policy.

## Recommended implementation slices

1. **#5868 URL/default directory fix** — make every agent creation path default to `DefaultWorkingDirectory.preferredURL`, including URL/deep-link creation. Small, user-visible, low risk.
2. **Resize propagation** — add the missing channel/controller resize seam and regression tests so broker-backed shells behave like iTerm under window and split-pane changes.
3. **Cwd truth seam** — wire OSC 7/host directory updates through broker-backed terminal processes; keep typed-input tracking only as fallback.
4. **Shell environment baseline** — explicitly set `TERM`, `LANG`, and `TERM_PROGRAM` for shell sessions and test them under `NativePTYBrokerSessionRuntime`.
5. **Interactive PTY smoke tests** — stable runtime coverage now proves `tty` reports a real `/dev/tty*` and `stty size` tracks initial plus resized broker grids; keep signal/job-control/full-screen TUI behavior for manual/app-hosted smoke unless a deterministic headless unit harness emerges.
6. **Scrollback/history policy** — handle under #7171/#5884 after correctness slices, because storage/privacy policy is broader than #7166.

## Board outcome

#7166 can be closed after this document is committed and the SwiftPM test suite still passes, because the card's deliverable is an audit with concrete gaps, reproductions, test targets, and implementation slices.

## Verification

Latest supervisor verification:

```bash
swift test --filter NativePTYBrokerSessionRuntimeTests
```

Result: 12 tests executed, 0 failures.
