# Holoscape Tank Backend Baseline

Status: initial execution for card #7165.

## What was verified

Environment on MacBook:

- Repo: `/Users/eriksjaastad/projects/holoscape`
- Branch: `plan/holoscape-tank-backend-roadmap`
- Swift: Apple Swift 6.3.3, target `arm64-apple-macosx26.0`
- Xcode: 26.6, build 17F113

Commands run:

```bash
swift test --list-tests
swift test
```

Results:

- `swift test --list-tests` exit code: 0
- `swift test` exit code: 0
- Parsed XCTest suite summaries: 2,838 executed test entries, 0 failures
- Final output included `Test Suite 'All tests' passed`

Important caveat: this is SwiftPM unit/property/integration coverage. It is not the full Xcode UI suite. The repo docs still describe UI-test history and Xcode project drift, so UI verification remains a separate baseline item.

Xcode/UI fast-suite attempt:

```bash
make test-ui-fast
```

Result:

- App bundle build/sign step completed.
- `xcodebuild test` reported `** TEST FAILED **`.
- The Makefile command pipes xcodebuild output through `grep -E "Test Case|Executed|TEST"`, so the first attempt did not expose the underlying compile/runtime failure.
- This confirms the UI/Xcode path is still not a trustworthy green gate and must be handled through #5988/#5866/#5876 before daily-driver claims.

## Current roadmap branch

Roadmap commit:

- `325162e Document Holoscape tank backend roadmap` (superseded by the follow-up baseline commit on this branch)

Roadmap file:

- `docs/tank-backend-roadmap.md`

## Baseline observations

### 1. The core SwiftPM test suite is currently green

This is a strong sign. The project is not in the same shape as older `round-9` docs that recorded large UI-test failures. Those docs should be treated as historical unless revalidated through the Xcode UI suite.

### 2. UI/screenshot tests remain the big unknown

Relevant existing cards:

- #5988 — sync Xcode project with SwiftPM sources
- #5866 — re-audit PRD vs current build
- #5876 — reconcile undocumented features

Do not call Holoscape tank-solid until the Xcode/UI path is either green or explicitly classified.

### 3. Session/process survival is not proven by SwiftPM tests

The green SwiftPM suite does not prove the app can survive:

- app quit while sessions run;
- app crash while agents run;
- laptop sleep/wake;
- relaunch and reattach;
- stale process cleanup.

Relevant roadmap cards:

- #7167 — choose session survival substrate
- #7168 — implement process/session survival

### 4. Persistent tab truth is not fully proven by SwiftPM tests

The code has notification primitives and tab/sidebar state surfaces, but daily-driver behavior still needs product-level acceptance:

- `ready` persists until user sees it;
- `needs approval` persists until cleared;
- Claude and Codex map to the same model;
- missed banners do not lose state.

Relevant roadmap cards:

- #7169 — persistent channel state model
- #7170 — Claude/Codex parity through adapters
- #5873, #5879, #40928601814757376, #5957, #5936

### 5. External integrations must stay plugin-shaped

Project Tracker can be useful immediately while Erik is still using Warp, but Holoscape core must not depend on it.

Relevant roadmap cards:

- #7173 — removable plugin architecture
- #7174 — first-party Project Tracker plugin
- #41929732032458752 — PT-backed Message Board, reframed as plugin work

## Immediate next recommended work

1. Finish this baseline card by adding Xcode/UI-suite status.
2. Then pick one of:
   - #7166 — terminal correctness audit against iTerm behavior; or
   - #7167 — session survival substrate decision.
3. Avoid feature work until the baseline and session/state foundations are understood.
