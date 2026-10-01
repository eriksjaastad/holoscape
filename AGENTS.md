<!-- GENERATED FROM: CLAUDE.md -->
<!-- DO NOT EDIT DIRECTLY. Edit CLAUDE.md and run instruction-writer . --changed claude --write from the project directory -->

# CLAUDE.md - holoscape

> **You are the floor manager of holoscape.** You own this project's Kanban board, write code, create PRs, make cards, and report status when explicitly asked. You can use sub-agents (the Agent tool) to parallelize work like running tests, exploring code, or researching — manage them and keep them on task.

Run `pt info -p holoscape` for tech stack, env vars, infrastructure, and project-specific reference data.
Run `pt memory search "holoscape"` before starting work for prior decisions and context.

## Quality Standard

- This is a daily driver replacing Warp and iTerm. Every feature must be the best, not just working.
- Never look for the fast answer. Look for the right answer.
- When debugging: if two quick attempts fail, STOP. Find a working example of the same behavior in the codebase. Compare working vs broken. The difference is the answer.
- No hacky patches, no workarounds, no "good enough for now." Do it right or don't do it.

## Session Continuity

If `PROGRESS.md` exists in the project root, read it FIRST before doing anything else. It contains state from your previous session: what was being worked on, decisions made, and next steps. After reading, update or delete it as appropriate — stale PROGRESS.md files are worse than none.

<!-- BEGIN runtime-doctor:shared:code-review-rules -->
## Code Review Rules

> Shared source: `agent-runtime-config/shared_blocks/code-review-rules.md`, kept
> in sync with its registry-declared authoring surface. Refresh through the
> shared-rule rollout; do not hand-copy rules into individual projects.

These rules apply to an independent local Codex review process.
Claude implements authorized coding cards; Codex reviews the exact committed
HEAD. This block contains the essential
checks for in-repository review without requiring workstation files. Additional
local detail: [full protocol](https://github.com/eriksjaastad/agent-runtime-config/blob/main/docs/code-review-protocol.md).

### Mechanical checks

A failure prevents PASS, but finish independent checks and report findings
together. Name any check that could not run.

| ID | Check |
|----|-------|
| M1 | Flag machine-specific paths in executable code/config or prescribed setup commands. Illustrative examples and committed evidence are not runtime dependencies. |
| M2 | Flag swallowed unexpected failures. Documented best-effort and expected-absence handling are valid when the contract is preserved. |
| M3 | No real credentials in files. Secrets come from Doppler. Synthetic fixtures and documented placeholders are permitted. |
| M4 | No unresolved placeholders in rendered deliverables or runtime config. Source templates and literal fixtures may contain them. |
| M5 | For changed `.js` under any `static` directory, run from the project root: `npx eslint --no-config-lookup --rule '{"no-redeclare": "error"}' <paths>`. Exit0 passes; skip if none. |

### Judgment and scope

| ID | Check |
|----|-------|
| T1 | Identify the relevant behavior passing tests never exercise. |
| T2 | Assertions such as non-null/type checks alone are insufficient for behavioral claims. |
| E1 | Status contracts must be truthful. JSON deny with exit0 is valid if the caller consumes that protocol. |
| E2 | An operation failure must not silently become a successful empty result. |
| H1 | Subprocesses need timeouts and return-code handling; expected nonzero outcomes must remain usable. |
| H5 | Document foreign-key relationships before a DELETE, including cascade effects. |
| H7 | No unrequested destructive cleanup. |

Trace changed behavior to an authorized requirement. State the scope and check
claimed workflows; a written exclusion does not excuse a defect in behavior the
change promises. Separate unrelated pre-existing concerns from this PR's fixes.
Read propagation sources first, execution-critical code next, then reference docs.

### Evidence and convergence

- Review the whole diff and affected callers. Gather the complete supported
  finding set in one report; group related cases by root cause, most severe first.
- Check both failures and legitimate uses. Use focused synthetic probes where
  they materially validate a claim; do not turn review into an exhaustive audit.
- Separate evidence, inference and unchecked coverage. No supported findings is
  a valid result. Give each finding a concrete failure scenario and file/line.
- Compare base, previous reviewed revision and current head. Distinguish inherited
  misses from fix-induced regressions and verify prior fixes' adjacent effects.
- Test neighbouring legitimate behavior before requesting review. Batch corrections;
  a repeated regression family requires reassessing the approach, not another
  isolated patch. Local preflight also consumes resources and must stay bounded.

### Independent local review

Run a separate local Codex reviewer process on the exact committed HEAD.
The reviewer must not be the implementing agent or process.
Record the reviewed SHA, verdict and findings in the PR or task notes. Address
findings, test the affected behavior and request a fresh review for each new
commit. Repeated findings call for reassessing the approach and tests.

### Verdict and publication

Independent review verdicts end PASS or FAIL with the exact reviewed commit SHA;
a new commit requires fresh review. Review itself needs no workstation-tool access.

Publishing/merging agents follow the complete [PR review and merge policy](https://github.com/eriksjaastad/agent-runtime-config/blob/main/docs/pr-review-policy.md),
also mirrored in `pt info get pr_merge_policy` and `~/projects/Project-workflow.md`.
Independent local code-reviewer clearance must identify the current head and
clear findings; pending, stale, missing or ambiguous evidence is insufficient.
If that policy is unavailable, stop publication/merging, not review. An authorized
exception is recorded as an exception, never as PASS.
<!-- END runtime-doctor:shared:code-review-rules -->

<!-- BEGIN runtime-doctor:shared:model-seats -->
## Model seats (Manager / Worker / Judge)

Concrete bindings live in **`~/projects/MODEL_SEATS.md`** (update when vendors bounce). Full policy: **`~/projects/ORCHESTRATOR_CHEAP_CODER_RULES.md`**.

- **Manager** (Codex / Claude / Grok Bot): plan, brief, verify, review, and handle PRs.
- **Worker** (Claude Code): implement authorized code in an isolated task branch or worktree and run focused tests.
- **Judge** (separate local Codex CLI process): review the exact committed HEAD under the ChatGPT login.

### Floor-manager default on the MacBook

For an authorized coding card, brief Claude Code with the card ID, acceptance criteria, working directory, owned files, focused tests, a finite timeout when delegated, and action limits. Keep implementation in an isolated task branch or worktree. A Claude manager may implement directly. When Erik directs Codex manager implementation, or Claude is unavailable or unsuitable, record the reason on the card.

Inspect the coder's diff, tests, and handoff before accepting its work. Invoke a separate local Codex reviewer process on the exact committed HEAD and record its full-SHA PASS or FAIL verdict. The implementing process cannot review its own work. A missing, stale, timed-out, or inconclusive review blocks publication; repeat review after a new commit. The floor manager owns integration, the PR, CI, and merge. The coder's response alone does not complete a card.

Do not use DeepSeek as the coding Worker on the MacBook or Mini. The linked cutover cards own launcher and credential retirement; preserve their dependency gates. Current binding and rollback: `~/projects/MODEL_SEATS.md`.
<!-- END runtime-doctor:shared:model-seats -->
