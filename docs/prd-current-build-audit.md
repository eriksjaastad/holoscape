# PRD vs Current Build Audit

Cards: #5866 — Re-audit PRD vs. current Holoscape build; #5876 — reconcile undocumented shipped features from the April audit.

## Summary

The current build is ahead of `PRD.md` in backend reliability, integration surfaces, setup diagnostics, plugin seams, and chrome/skin infrastructure. The drift is mostly under-documentation, not code that should be removed. The core product direction remains valid: Holoscape should be a self-contained reliable terminal first, with external systems behind removable plugin seams.

## Highest-priority PRD drift

### 1. Session survival substrate is now a core architecture, not just a goal

Evidence:
- `Sources/Holoscape/Services/BrokerSessionCoordinator.swift`
- `Sources/Holoscape/Models/BrokerSessionRecord.swift`
- `Sources/Holoscape/Services/BrokerSessionHost.swift`
- `Sources/Holoscape/Services/NativePTYBrokerSessionRuntime.swift`
- `docs/session-survival-substrate.md`

Current PRD drift:
- The PRD still describes local shell and agent channels as direct SwiftTerm PTY processes.
- Crash resilience is listed as a requirement, but the PRD does not describe the durable broker/session lifecycle that now implements it.

Recommendation:
- Document the broker/session lifecycle in the PRD: durable session IDs, out-of-process host, detach/reattach, stale recovery, and loud diagnostics on broker failures.
- Do not remove this code; it is the tank-backend foundation.

### 2. Persistent tab truth exists and should replace the older active/disconnected/connecting model

Evidence:
- `Sources/Holoscape/Models/PersistentChannelState.swift`
- `Sources/Holoscape/Models/AgentStatusAdapter.swift`
- `docs/agent-status-adapters.md`
- `docs/tank-backend-roadmap.md`

Current PRD drift:
- The PRD only names simple channel state and running indicators.
- The build now has durable tab states with source priority, clearing rules, and agent/operator/plugin metadata.

Recommendation:
- Document the durable state taxonomy: ready, running, needs approval, error, stale/offline.
- Document the source-priority rule so plugin metadata cannot hide higher-priority terminal or agent states.

### 3. Disk-backed scrollback/history persistence is a product contract

Evidence:
- `Sources/Holoscape/Services/DiskBackedScrollbackStore.swift`
- `Sources/Holoscape/Services/ScrollbackPersistencePolicy.swift`
- `docs/scrollback-history-persistence.md`

Current PRD drift:
- The PRD says scrollback is configurable but does not state that broker-backed sessions persist bounded scrollback to disk and replay it on reattach.

Recommendation:
- Document the bounded FIFO persistence policy and privacy stance: anything printed to terminal output may be restorable until evicted by retention limits.

### 4. Plugin architecture has shipped as a removable seam, not a marketplace

Evidence:
- `Sources/Holoscape/Plugins/PluginManifest.swift`
- `Sources/Holoscape/Plugins/PluginManager.swift`
- `Sources/Holoscape/Plugins/PluginCommandRouter.swift`
- `Sources/Holoscape/Services/PluginStorageService.swift`
- `docs/plugin-architecture.md`

Current PRD drift:
- The PRD still lists plugin/extension model under V4 Someday.
- The build already includes a small first-party plugin seam with closed capabilities, closed permissions, plugin-scoped failures, and namespaced storage.

Recommendation:
- Move the removable plugin seam into the current architecture section.
- Keep plugin marketplace/community extension distribution as a non-goal.

### 5. Project Tracker integration is implemented as an optional first-party plugin and must stay out of core

Evidence:
- `Sources/Holoscape/Plugins/ProjectTrackerPlugin.swift`
- `docs/plugin-architecture.md`
- `Sources/Holoscape/Models/HoloscapeConfig.swift`

Current PRD drift:
- The PRD does not mention Project Tracker at all.

Recommendation:
- Document Project Tracker as an optional first-party plugin: disabled by default unless configured, localhost health/task-status integration, board/task URL commands, plugin-scoped failures, no core startup dependency.
- Do not make Project Tracker a core source of truth.

### 6. Local HTTP API and HoloscapeMCP are production integration surfaces

Evidence:
- `Sources/Holoscape/Services/HoloscapeAPIServer.swift`
- `Sources/HoloscapeMCP/main.swift`
- `Sources/HoloscapeMCP/Tools.swift`
- `Sources/HoloscapeMCP/HoloscapeClient.swift`
- `scripts/setup.sh`
- `scripts/notify-hook.sh`

Current PRD drift:
- The PRD describes a future MCP client-style CEO channel, but not the shipped MCP server path for Claude Code controlling Holoscape.
- The PRD does not document the local HTTP API on port 7865 or notification hook events.

Recommendation:
- Document the local HTTP API and MCP server direction separately from the future MCP client/CEO channel.
- Document notification hook event types: `permission_prompt`, `idle_prompt`, `auth_success`, and `elicitation_dialog`.

### 7. Setup diagnostics and macOS permission policy are product surfaces

Evidence:
- `Sources/Holoscape/SetupDiagnosticsWindowController.swift`
- `Sources/Holoscape/Services/SetupDiagnosticsService.swift`
- `SETUP.md`
- `docs/first-launch-setup-permissions.md`
- `docs/macos-permission-audit.md`

Current PRD drift:
- The PRD says notification permission is requested on first launch, but the implementation defers notification authorization until first eligible background notification.
- The PRD does not mention setup diagnostics or permission inventory.

Recommendation:
- Document `Holoscape > Setup Diagnostics…` and the policy: no broad permissions at launch, diagnose clearly, deep-link to System Settings when useful, fail loudly for config/broker/plugin misconfiguration.

### 8. Chrome/skinning/split/pinning surfaces are more mature than the PRD claims

Evidence:
- `Sources/Holoscape/Controllers/ShapedWindowController.swift`
- `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift`
- `Sources/Holoscape/Rendering/MetalCompositor.swift`
- `Sources/Holoscape/Rendering/ShaderCompiler.swift`
- `Sources/Holoscape/Views/SplitPaneView.swift`
- `Sources/Holoscape/Models/ChannelMetadata.swift`
- `docs/skins/`
- `Sources/Holoscape/Resources/Skins/MercuryDeck/`

Current PRD drift:
- The PRD still marks skin engine detail as deferred and lists split panes/tab pinning as V3 next-sprint items, while code and README show these as present.

Recommendation:
- Re-baseline the MVP/current scope section so shipped surfaces are no longer labeled future work.
- Keep visual polish cards separate from tank-backend reliability work.

## Known correctness gaps that should remain visible

Evidence:
- `docs/terminal-correctness-iterm-audit.md`

Gaps to keep visible in PRD or cards:
- Broker-backed resize propagation to child PTY.
- Current working directory truth through OSC 7/broker paths.
- URL-scheme agent channel default directory behavior.
- Shell profile environment guarantees such as `TERM=xterm-256color`.
- Controlling-TTY semantics.
- Scrollback replay view-tail limits versus persisted store limits.

## Card recommendations

Documented in PRD by this audit stream:
- Session broker substrate.
- Persistent tab state/source priority.
- Disk-backed scrollback persistence.
- Setup diagnostics and permissions policy.
- Local HTTP API and HoloscapeMCP tool server.
- Local `/notify` hook behavior for agent event notifications.
- `holoscape://` URL-scheme channel opener.
- Native Edit menu behavior.
- Font settings and appearance persistence.
- Directory persistence/restoration expectations.
- Removable plugin seam and optional Project Tracker plugin.

Create or keep separate cards:
- Verify Synth Insight Labs bug-report endpoint status and update PRD risk table.
- Reconcile notification settings schema with implemented notification-hook event model.
- Add Gemini/Ollama status adapters only if still needed.
- Continue skin/chrome roadmap as visual/product polish, not tank-backend blocker.

Rip out:
- None found. The drift is under-documented shipped surface area, not code that violates the removable-integration boundary.
