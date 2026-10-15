# Archived documentation

These files are historical evidence, not current requirements. Do not create new
implementation work from them without first reconciling the claim with
[`DECISIONS.md`](../../DECISIONS.md), [`PRD.md`](../../PRD.md), current code, and tests.

- [`discovery-brief-2026-04-03.md`](discovery-brief-2026-04-03.md) — original pre-native-rebuild discovery and
  version framing; superseded by [`PRD.md`](../../PRD.md) and [`DIRECTION.md`](../../DIRECTION.md).
- [`prd-current-build-audit.md`](prd-current-build-audit.md) — reconciliation audit whose current findings
  were incorporated into [`PRD.md`](../../PRD.md), [`README.md`](../../README.md), [`SETUP.md`](../../SETUP.md), and [`DECISIONS.md`](../../DECISIONS.md).
- [`session-survival-substrate.md`](session-survival-substrate.md) — decision record for choosing the native
  broker over tmux/dtach/abduco; implementation details and the old three-state
  channel model are superseded by [`DECISIONS.md`](../../DECISIONS.md) and
  [`docs/session-survival-phase1-audit.md`](../session-survival-phase1-audit.md).
- [`first-launch-setup-permissions.md`](first-launch-setup-permissions.md) — implementation close-out record;
  operator guidance now lives in [`SETUP.md`](../../SETUP.md) and the current prompt inventory in
  [`docs/macos-permission-audit.md`](../macos-permission-audit.md).
- [`project-tracker-message-board-plan.md`](project-tracker-message-board-plan.md) — non-normative plugin/message-ledger
  design evidence. Its router-sidecar assumptions are retired, while its ownership
  split remains useful context; current integration boundaries live in [`DECISIONS.md`](../../DECISIONS.md)
  and [`docs/plugin-architecture.md`](../plugin-architecture.md).

Archiving preserves provenance while preventing old launch ownership, state, and
roadmap descriptions from competing with current contracts.
