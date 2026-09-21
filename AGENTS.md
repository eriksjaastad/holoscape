<!-- GENERATED FROM: ~/projects/holoscape/CLAUDE.md -->
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

> **Authored once, here. Propagated into every repo's `AGENTS.md` so the reviewer sees it
> in-repo.** Do not hand-copy this into a project file — if it is missing from a repo, that
> is a propagation bug, not a licence to paste.

These are the standards every PR is reviewed against, by whoever or whatever is reviewing.
They are written provider-neutral on purpose: Codex, Claude and any future reviewer read the
same list.

### Gate 0 — mechanical scan

A failure prevents a PASS, but does not end the review. Complete all independent
checks and the judgment audit, then report the supported findings together.
If a failure prevents a check from running, identify that coverage gap.

| ID | Check |
|----|-------|
| M1 | **Portable paths.** Flag machine-specific paths wired into executable code/config or prescribed setup commands. Illustrative examples, incident evidence, and committed data breadcrumbs are not runtime dependencies; do not reject them merely for spelling a path. |
| M2 | **No swallowed unexpected failures.** Flag `except: pass` when it hides an operation failure from the caller. Explicit best-effort or expected-absence handling is valid when the documented contract is preserved. |
| M3 | No real API keys, tokens, or credentials in files. Secrets come from Doppler. Clearly synthetic test fixtures and documented placeholders are permitted. |
| M4 | No unresolved placeholders in rendered deliverables or runtime configuration. Source templates and literal test fixtures may intentionally contain placeholders. |
| M5 | No JS redeclarations in changed `.js` files beneath any directory named `static`, at any depth (including nested subdirectories). If the diff touches any, run from the project root: `npx eslint --no-config-lookup --rule '{"no-redeclare": "error"}' <paths>`. Exit 0 = pass. Skip when the diff has no static JS. |

### Judgment checks — what automation cannot see

| ID | Check |
|----|-------|
| T1 | **Inverse test audit.** Not "do tests pass" but *what do the passing tests never exercise*. Name the dark territory. |
| T2 | **No weak assertions.** `isinstance(x, T)` or `x is not None` alone asserts almost nothing. |
| E1 | **Status contracts are truthful.** Check the documented exit/status protocol. A hook that returns a deny decision in JSON with exit 0 is valid when its caller consumes that protocol. |
| E2 | **No silent failure returns.** `return []` or `return ""` on a failed operation, with nothing logged, is a defect — the caller cannot tell empty from broken. |
| H1 | **Subprocess integrity.** Use a timeout and handle failure through `check=True` or explicit validation of expected return codes. Expected nonzero results must remain usable; unexpected failures must not silently become success. |
| H5 | **CASCADE DELETE documented.** Foreign-key relationships are spelled out before any `DELETE` lands. |
| H7 | **No unrequested auto-cleanup.** A "helpful" destructive addition nobody asked for is a defect, not a bonus. |

### Scope and authorisation

- **Was this behaviour actually requested?** If no, reject it — however good it is.
- **Does the change stay inside the task it claims?** Scope creep is a finding.
- **Can every change trace to a requirement?** If it traces to nothing, say so.

### Review in blast-radius order

A Tier 1 defect propagates into every downstream project, so it is read first.

- **Tier 1** — `templates/`, `AGENTS.md`, `CLAUDE.md`: propagation sources.
- **Tier 2** — `scripts/`, `scaffold/`: execution critical.
- **Tier 3** — `docs/`, `patterns/`, rules files: human reference, no code impact.

### Verdict

Local and delegated review reports end in **PASS** or **FAIL**, pinned to the
**exact commit SHA** reviewed. State that SHA in the verdict; a new commit requires
a fresh review. A local or sub-agent PASS does not replace the Codex GitHub gate.

GitHub reviewers report supported findings or a clean result in the integration's
normal format. Reviewing code does not require access to workstation tools or
merge-policy mirrors.

Agents publishing or merging a PR must follow the complete
[PR review and merge policy](https://github.com/eriksjaastad/agent-runtime-config/blob/main/docs/pr-review-policy.md).
Local installations also expose that same policy through `pt info get pr_merge_policy`
and `~/projects/Project-workflow.md`. A clean review object, completed summary, or
fresh connector thumbs-up observed on an unchanged recorded head can qualify under
that procedure without a literal PASS token. The evidence must identify the current
commit and clear findings. Pending, missing, ambiguous, or stale evidence does not
pass. If the complete policy is unavailable, stop publication or merging; this does
not prevent a reviewer from completing the code review. An explicitly authorized
exception is recorded as an exception, never as a PASS.

### How to report

Shape, not standards. Drip-fed findings cost a full cycle each — a new commit
invalidates the prior review, so a five-finding diff becomes five reviews.

- **One review per request, covering the whole diff.** Every finding, most
  severe first, each with `file:line` and a concrete failure scenario. Never
  hold one back for a later round.
- **Separate evidence from uncertainty.** Findings need a concrete failure
  scenario. Report unverified concerns as questions or coverage gaps, not defects.
  A review with no supported findings is valid; do not manufacture issues.
- **Rank use-case breakage above hypothetical hardening.** A P2 that silently
  breaks the primary workflow outranks a serious-looking edge case nobody hits.
  Say which class a finding is in.
- **Say where the change is too strict** — where it refuses, blocks or rejects
  something it should accept. Implementers cannot see this in their own work, so
  it is the direction least likely to be found without you.
- **If the diff answers your previous findings, say so**, and check whether those
  fixes opened adjacent surface. Most late-round defects live there.

### Review convergence

- **Review the behavior, not only the changed lines.** Trace affected callers,
  consumers, and execution paths. When a defect appears, inspect related forms
  before submitting the review; group examples with the same root cause.
- **Check both failure and legitimate use.** For parsers and filters, cover the
  relevant syntax variants, wrappers, normalization, and safe counterparts. For
  synchronization and conversion, check round trips and preservation of authored
  content. Select cases from the actual contract; unrelated exhaustive audits are
  outside the PR's scope.
- **Verify fixes against history.** Compare relevant behavior with the base and
  previous reviewed revision. Distinguish incomplete fixes, newly introduced
  regressions, and pre-existing issues outside the changed behavior. On follow-up
  reviews, verify prior findings and adjacent effects, retaining whole-diff context.
- **Aim to converge in two or three reviews.** If the same defect family returns,
  reassess the implementation and test coverage before another narrow patch.
  The target never waives a finding, required check, or exact-head review.
<!-- END runtime-doctor:shared:code-review-rules -->
