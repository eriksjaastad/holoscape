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

<!-- BEGIN scaffold:hygiene -->
## Locked Hygiene Contract

This project participates in the portfolio-wide locked hygiene contract.
Hygiene guidance now lives in agent-runtime-config; the contract is still enforced by user-scope
hooks in `~/.claude/` and by `pt` CLI commands in project-tracker. **Treat this block as the portfolio hygiene contract.** Markers are author-owned (not auto-rewritten). Prefer updates guided by agent-runtime-config docs; add project-specific notes outside the markers.

### What the contract requires

1. **No direct edits on `main`/`master`/`trunk`.** A Stop-event hook blocks
   `Edit`/`Write`/`MultiEdit`/`NotebookEdit` on tracked files while HEAD is the
   default branch. Work happens on feature branches; PRs are how changes land.
2. **No dirty session exits.** A session-end gate refuses to close while any of
   four conditions hold:
   - dirty working tree (PROGRESS.md is ignored),
   - commits ahead of upstream unpushed,
   - branch with no PR opened,
   - an authored PR still open against this repo.
3. **Audit trail for bulk changes.** Multi-file refactors, renames, and doc
   reorgs run inside `pt migration start <name>` … `pt migration finish <name>`
   so they are reversible (`--revert` uses `git restore` for tracked paths and
   `send2trash` for untracked — never raw `rm`).
4. **Handoffs are first-class.** If a session must end dirty (mid-rebase, mid-
   investigation), record it: `pt handoff create <card-pk> --branch <b> --intent
   <s> --status <s> --next <s> --guidance preserve|discard`. The session-end
   gate honors an open handoff covering the current branch.

### Safety valves

- **`.scratch/`** — every project has a gitignored `.scratch/` at its repo root.
  The branch-on-first-edit hook lets edits under any `.scratch/` subdir through
  unconditionally. Use it for throwaway notes, probe scripts, and reading-mode
  poking. Files there never reach a PR. If `.scratch/` work turns into real work,
  move it out before committing.
- **`PT_ALLOW_MAIN_EDIT=1`** — one-shot env var to bypass the main-edit hook.
  Use sparingly; intended for emergency fixes and tooling that must touch the
  default branch.
- **`PT_ALLOW_DIRTY_EXIT=1`** — one-shot env var to bypass the session-end gate.
  Every use is logged to `~/.claude/state/locked_hygiene/bypasses.jsonl`.
- **`pt handoff`** — durable alternative to the env-var bypass: the gate
  recognizes an active handoff record for the current branch and lets the
  session close.

### Quick reference

| Action                          | Command                                       |
| ------------------------------- | --------------------------------------------- |
| Start a recorded bulk migration | `pt migration start <name>`                   |
| Finish + write `MIGRATIONS.md`  | `pt migration finish <name>`                  |
| Revert a migration              | `pt migration finish <name> --revert`         |
| Open a handoff                  | `pt handoff create <card-pk> --branch <b> …`  |
| List open handoffs              | `pt handoff list`                             |
| Resolve a handoff               | `pt handoff resolve <id>`                     |
| Refresh this block portfolio-wide | Manual / agent-runtime-config guidance (scaffold sync CLI retired #6833) |
<!-- END scaffold:hygiene -->

<!-- BEGIN runtime-doctor:shared:code-review-rules -->
## Code Review Rules

> Shared source: `agent-runtime-config/shared_blocks/code-review-rules.md`, kept
> in sync with its registry-declared authoring surface. Refresh through the
> shared-rule rollout; do not hand-copy rules into individual projects.

These rules apply to Codex and Claude local reviewers. Codex is primary; Claude
remains supported. This block contains the essential checks for in-repository
review without requiring workstation files. Additional local detail:
[full protocol](https://github.com/eriksjaastad/agent-runtime-config/blob/main/docs/code-review-protocol.md).

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

### Three independent review cycles: assess the result

The initial independent review execution counts. Persist the work item's distinct
review cycles, request/acknowledgement evidence, head SHAs and outcomes in its
PR/task notes. Multiple comments or findings from one cycle are not multiple
reviews. Count acknowledged failed/stalled executions; resolve uncertain history
before triggering another. Follow the full PR policy's counting rules before
pushes, requests, retries and merges.

The third cycle may be requested after fixes and preflight. At that request or
detection of an automatic third cycle, all agents on that work item stop edits,
commits, pushes, further review requests and merges. Let that review finish.
A clean third review on the unchanged recorded head may merge when CI and all
other gates pass, without extra approval solely for its count. If findings remain,
report the PR, SHA, findings, cycle evidence and recurring patterns to Erik; stop
further fixes or requests until he directs the next step. Pending, unknown,
ambiguous or stale evidence is not clearance; existing wait limits and unrelated
user holds still apply. Do not reset the count by changing agents/sessions/branches
or splitting/recreating the PR. A fourth cycle requires Erik's explicit direction;
this never waives correctness or CI.

### Verdict and publication

Independent review verdicts end PASS or FAIL with the exact reviewed commit SHA;
a new commit requires fresh review. Review itself needs no workstation-tool access.

Publishing/merging agents follow the complete [PR review and merge policy](https://github.com/eriksjaastad/agent-runtime-config/blob/main/docs/pr-review-policy.md),
also mirrored in `pt info get pr_merge_policy` and `~/projects/Project-workflow.md`.
Independent review clearance must identify the current head and clear findings;
pending, stale, missing or ambiguous evidence is insufficient. If that policy is
unavailable, stop publication/merging, not review. Third-review findings require
a human discussion; clean third-review clearance follows the normal merge gates.
An authorized exception is recorded as an exception, never as PASS.
<!-- END runtime-doctor:shared:code-review-rules -->
