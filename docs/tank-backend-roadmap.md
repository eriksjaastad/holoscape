# Holoscape Tank Backend Roadmap

Status: execution roadmap, created for umbrella card #7164.

## Product rule

Holoscape core is self-contained. It should become a rock-solid native macOS terminal first, then a visually distinctive terminal. External systems are optional plugins, not core dependencies.

That means Project Tracker, Kanban, message ledgers, cross-computer sync, agent addressing, and handoff semantics can be first-party plugins for Erik's workflow, but Holoscape must still work completely without them.

## North star

Holoscape should feel wild on the outside and conservative underneath:

- backend reliability like iTerm;
- less AI/product clutter than Warp;
- persistent, truthful session state instead of disappearing banners;
- skins that reflect real terminal/agent state without destabilizing terminal behavior.

## Umbrella card

- #7164 — Roadmap: make Holoscape a tank-solid self-contained terminal before feature expansion

## Phase 0 — Baseline before more feature breadth

Purpose: know what works, what is stale, and what blocks safe development.

New cards:
- #7165 — establish Holoscape tank-backend baseline and acceptance gates
- #7164 — create this roadmap doc linking existing and new cards

Existing cards folded into this phase:
- #5866 — re-audit PRD vs current Holoscape build
- #5876 — PRD vs code audit; reconcile undocumented features
- #5973 — add submodule-init guard for fresh clones
- #5988 — sync Xcode project with SwiftPM sources

Definition of done:
- clean build/test baseline is known;
- flaky/blocked UI tests are classified, not ignored;
- PRD/code drift is listed;
- fresh clone setup failures are loud and actionable;
- no new feature work is accepted until baseline failures are either fixed or explicitly parked.

## Phase 1 — Tank terminal foundation

Purpose: Holoscape must be a reliable terminal before it becomes a clever agent cockpit.

New cards:
- #7166 — terminal correctness audit against iTerm daily-driver behavior
- #7167 — choose session survival substrate: native PTY manager vs tmux/dtach/abduco. Decision: Holoscape-owned native session broker; see `docs/session-survival-substrate.md`.
- #7168 — implement process/session survival across app quit and crash; blocked by #7167

Existing cards folded into this phase:
- #5868 — agent channel opens in `/` instead of `~/projects`
- #5862 — one-keystroke local shell
- #5864 — Agent OAuth channel creation needs directory/label prompt
- #5867 — unify session launcher dropdown with New Channel

Definition of done:
- normal shell usage feels boringly solid;
- app quit/crash does not silently destroy important sessions;
- cwd, labels, launch directory, relaunch, and process lifecycle are deterministic;
- failures are explicit and recoverable.

## Phase 2 — Persistent tab truth

Purpose: banners are secondary. The tab/sidebar must hold the truth until the user clears it.

New cards:
- #7169 — define persistent channel state model for running/ready/needs-approval/error/stale
- #7170 — make Claude/Codex agent status parity work through adapters; blocked by #7169

Existing cards folded into this phase:
- #5873 — off-screen notification UX: dock badge, click-through focus, per-channel mute
- #5879 — tab background color when Claude awaits user decision
- #40928601814757376 — expand CLI/client detection to include Codex
- #5957 — tab agent indicator: Claude, Codex, Gemini, Ollama, SSH
- #5936 — last interaction timestamp + stale-tab badge
- #5878 — strip noisy elapsed timer; maybe replace with useful last-interaction signal
- #5872 — user and agent text look identical in agent channels

Definition of done:
- channel state taxonomy exists and is testable;
- Claude and Codex map into the same state system through adapters;
- tab/sidebar state persists until focused/cleared;
- skins can consume state later, but core state does not require skins.

## Phase 3 — Scrollback and history persistence

Purpose: restart should not erase the user's working context.

New cards:
- #7171 — make scrollback/history persistence daily-driver reliable

Existing cards folded into this phase:
- #5884 — scrollback persistence across restart

Definition of done:
- relaunch restores useful per-channel context;
- storage limits and privacy behavior are explicit;
- state corruption or secret leakage is tested against;
- works with the session-survival decision from Phase 1.

## Phase 4 — Setup and macOS permissions

Purpose: a tank terminal cannot surprise the user with repeated TCC prompts or hidden setup mutations.

New cards:
- #7172 — harden first-launch setup and macOS permission flow

Existing cards folded into this phase:
- #5870 — repeated network volume permission prompt
- #5871 — audit all macOS permission prompts
- #5881 — first-launch setup and permissions guide

Definition of done:
- user-scope setup actions are explicit;
- permissions are inventoried and explained;
- common prompts are handled once, not repeatedly;
- setup failure is loud and actionable.

## Phase 5 — Plugin seam and Project Tracker plugin

Purpose: Holoscape remains self-contained. External systems attach through removable plugins.

New cards:
- #7173 — define removable plugin architecture for external integrations. Architecture: `docs/plugin-architecture.md`.
- #7174 — implement first-party Project Tracker plugin after plugin seam exists; blocked by #7173

Existing cards folded into this phase:
- #41929732032458752 — implement PT-backed Message Board channel; reframed as optional plugin work
- #5654 — ProcessTool via agent
- #5655 — FileSystemTool via agent
- #5657 — AppleScriptTool via agent

Plugin boundary rule:
- Project Tracker can own the early message ledger while Erik is still using Warp.
- Holoscape can later ship a first-party Project Tracker plugin.
- No Project Tracker dependency belongs in core terminal startup, core session lifecycle, or core tab state.
- Third-party trackers should be possible later without rewriting core.

Definition of done:
- plugin lifecycle, permissions, storage ownership, failure behavior, and UI contribution points are documented;
- core Holoscape runs with no plugins;
- disabling a plugin removes its features cleanly.

## Phase 6 — Skin state integration after the core is stable

Purpose: Erik owns what looks cool; agents make the state safe and reliable.

New cards:
- #7175 — connect skin visuals to real terminal/channel state without destabilizing core

Existing cards folded into this phase:
- #6030 — 2026 Winamp / shaped windows / real skinning
- #5888 — SkinEngine audit
- #5930 — Ghostty shader pipeline
- #5945 — agent-state reactivity + red-pulse demo
- #5946 — shader discovery, hot reload, compile-failure banner

Definition of done:
- MercuryDeck can show real state through LEDs/glows/meters;
- turning skins off leaves terminal/session behavior unchanged;
- visual polish never masks backend failure;
- skin errors degrade loudly but safely.

## Immediate execution order

1. Finish #7164 and commit this roadmap.
2. Start #7165 and use #5866/#5876/#5973/#5988 as inputs.
3. Start #7166 or #7167 depending on whether the next worker is better suited to testing or architecture research.
4. Keep unrelated watch cards out of this roadmap unless Erik explicitly pulls them in.

## Non-goals for the next stretch

- Do not build a hardwired Project Tracker dependency into Holoscape core.
- Do not chase broad skin features before tab/session state is reliable.
- Do not add Warp-like AI bells and whistles just because they are fashionable.
- Do not treat disappearing banners as sufficient notification UX.
- Do not make terminal correctness depend on skins, plugins, or external services.
