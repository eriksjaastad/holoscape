# Holoscape — Session Handoff (2026-04-14)

## Read this first
- Branch: `docs/ghostty-investigation` — not yet pushed, not yet PR'd.
- The prior 2026-04-12 handoff (New Channel UX cluster, permissions audit, notifications) is still valid as a backlog map. We just aren't working on it right now — we're in research mode for the skin system. Don't pivot back to those cards without Erik saying so.

## Current focus
Investigate Ghostty's shader + overall architecture to (a) inform the skin scope doc (#5887) and (b) identify non-skin subsystems worth borrowing. Companion to `docs/skins/01-research-winamp-and-modern-equivalents.md`, which has a stale §6 that this investigation corrects.

**Reference checkout:** `~/projects/github-repos/ghostty` (shallow, read-only). Always cite file + line when making claims about Ghostty's implementation.

## First pass — done
`docs/skins/04-ghostty-investigation.md` covers:
- Shader pipeline (GLSL → SPIR-V → MSL via glslang + spirv-cross)
- Uniform block and the current/previous/timestamp reactivity pattern
- Correction to `01-research` §6: reactivity is not the differentiator; **agent-state reactivity** is
- Power/animation mode, shader loading mechanics, compile-failure robustness
- Part B: six general-architecture subsystems (Command Palette, Global Keybinds, QuickTerminal, Splits, App Intents/AppleScript, `NSTextInputClient`)
- Part C: proposed cards bucketed into skinning vs. general
- Part D: open questions

## Second pass — in progress
Sharpen, verify, deepen against live source:

1. **Verified citations.** First pass's "around line 2200" and "~3045" both confirmed. Prefix length corrected 50 → 53. Selection fg/bg order corrected.
2. **Expanded A.2 with verbatim code.** Diff-and-stamp block at `generic.zig:2197-2207` included. Added the two-path update model — state-driven `updateCustomShaderUniformsFromState` at :2010 (gated on `terminal_state.dirty`, handles palette/colors/cursor-style) and per-frame `updateCustomShaderUniformsForFrame` at :2102 (cursor-position diff + focus stamping). The draft's "each frame, diff" was oversimplified.
3. **New A.4: agent-state uniform extension — design.** Load-bearing new content. Lists the event categories worth exposing (output, command lifecycle, agent state, channel state, notifications), proposes concrete uniform names, reuses Ghostty's diff-and-stamp pattern, includes a worked shader example.
4. **New decision table in A.9** (old A.7): adopt / extend / skip columns for each Ghostty subsystem.
5. **New Part E: Decisions.** Pipeline choice (GLSL → SPIR-V → MSL) promoted from open question to committed decision with reasoning.

## After second pass lands
1. Open PR from this branch (draft → Erik review → merge).
2. Follow-up small PR: update `01-research` §6 with the corrected positioning.
3. Create cards from Part C after Erik reviews buckets:
   - **Skinning bucket:** port shader pipeline, write `05-reactive-uniforms.md` (if the A.4 design graduates), write `06-chrome-skinning.md`, research-doc correction.
   - **General bucket:** Command Palette spike, Global Keybinds spike, Splits spike, `NSTextInputClient` spike, threading audit. `libghostty-vt` audit deferred until it tags a version.
4. Feed skinning-bucket output into scope doc #5887.

## Don't
- Don't push this branch yet — second pass isn't finished.
- Don't open cards from Part C until Erik reviews the doc.
- Don't reopen Round 11 or the 2026-04-12 backlog clusters. They're parked.

## Housekeeping (this session)
- On branch entry, the WIP was committed as `7ec6c14 chore: wip snapshot of ghostty investigation branch` to enable a brief excursion to `main` (which turned out to be unnecessary — the `claude-review` workflow disable is already at `33ca335` on both local and origin).
- Two `Odin_macOS_app_icon_*.png` concept images moved from repo root into `app-icon-replacements/`. They are AI-generated app-icon candidates; one variant is already in use, the rest are kept for reference.

## First moves next session
1. `git status && git log --oneline -5` — confirm branch state.
2. Re-read `docs/skins/04-ghostty-investigation.md` before editing.
3. If second pass is already merged, move on to PR-ing the `01-research` §6 correction.
