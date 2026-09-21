# Removable plugin architecture for external integrations

Status: Phase 5 architecture definition for Kanban card #7173, with initial manifest/registry substrate for #7174.

## Goal

Holoscape core remains a complete terminal when every plugin is disabled or absent. External systems such as Project Tracker, message ledgers, cross-computer sync, agent addressing, handoff semantics, and third-party trackers attach through explicit plugin seams.

This document defines the architecture boundary before any Project Tracker-specific implementation. It is intentionally conservative: no plugin may become required for terminal startup, session survival, tab truth, scrollback replay, shell/agent process launch, or setup/permission flow.

## Non-goals

- Do not implement the Project Tracker plugin in core.
- Do not make Kanban cards, message ledgers, or remote sync the source of truth for Holoscape channels.
- Do not let plugin failures silently downgrade terminal behavior.
- Do not add a plugin marketplace, scripting runtime, or arbitrary code loading in this slice.

## Core/plugin boundary

Core owns these invariants and must not delegate them to plugins:

1. **Process/session lifecycle** — broker session ids, PTY process ownership, lifecycle recovery, stale/error recovery actions.
2. **Terminal correctness** — PTY input/output, resize propagation, cwd truth, environment baselines, scrollback replay.
3. **Persistent channel state** — ready/running/needs-approval/error/stale model and clearing rules.
4. **Config/bootstrap** — `~/.holoscape` or `$HOLOSCAPE_CONFIG_DIR`, first-window launch, default shell/agent creation.
5. **Local privacy/storage policy** — core persistence formats and retention limits.
6. **UI safety** — a plugin can contribute optional surfaces, but core tabs/sidebar/terminal panes remain usable without it.

Plugins may contribute optional behavior through narrow capability interfaces:

| Capability | Examples | Must be removable by |
| --- | --- | --- |
| Channel provider | Project Tracker message-board channel, future third-party tracker channel | Hiding/removing plugin channel profiles and refusing new plugin-channel opens |
| Status adapter | Tracker/handoff state shown as supplemental badge text | Dropping adapter updates while preserving core channel state |
| Command provider | Optional actions such as “open task”, “create handoff” | Removing commands from menus/palettes |
| Notification provider | External workflow alerts routed into Holoscape | Disabling provider notifications without affecting local unread notifications |
| Storage provider | Plugin-owned cache or credentials metadata | Deleting plugin storage without touching broker/session/scrollback stores |

## Plugin lifecycle

A plugin has a deterministic lifecycle managed by a future `PluginManager` service:

1. **Discovered** — a plugin manifest is found in a configured plugin directory or bundled first-party plugin list.
2. **Validated** — manifest id/version/capabilities/permissions/storage namespace are schema-checked before any plugin code or network client is constructed.
3. **Configured** — user settings enable or disable the plugin and supply plugin-specific options.
4. **Started** — plugin receives core service handles matching only its declared capabilities.
5. **Running** — plugin may publish optional channels, commands, status updates, and notifications.
6. **Suspended** — plugin remains installed but its runtime work is stopped, e.g. offline mode or temporary failure.
7. **Disabled** — plugin contributions disappear from UI and no background work runs.
8. **Uninstalled** — plugin manifest/runtime are removed; plugin-owned storage may be pruned explicitly.

Startup rule: Holoscape starts core first, opens/restores terminal channels, then starts enabled plugins. A plugin start failure must create a plugin-scoped error record and optional warning surface; it must not block the main window, shell creation, agent creation, broker recovery, or scrollback replay.

## Manifest shape

A plugin manifest should be declarative and small enough to validate before side effects:

```json
{
  "id": "com.holoscape.project-tracker",
  "displayName": "Project Tracker",
  "version": "1.0.0",
  "minimumHoloscapeVersion": "0.1.0",
  "capabilities": ["channel-provider", "command-provider", "status-adapter"],
  "permissions": ["network:localhost", "filesystem:plugin-storage"],
  "storageNamespace": "project-tracker",
  "entrypoint": {
    "kind": "xpc-service",
    "bundleIdentifier": "com.holoscape.plugins.project-tracker"
  }
}
```

Validation rules:

- `id` is globally unique and stable.
- `capabilities` are from a closed enum owned by core.
- `permissions` are from a closed enum owned by core.
- `storageNamespace` cannot overlap core stores such as `config`, `sessions`, `scrollback`, `skins`, or `crash-reports`.
- The manifest is rejected before start if a requested capability lacks its required permission.
- Rejection is explicit and visible in plugin diagnostics; there is no silent fallback to broader access.

## Permissions

Plugin permissions are narrower than macOS TCC permissions and must be enforced before plugin start:

- `network:localhost` — local HTTP/WebSocket calls only, e.g. `http://localhost:8000` for Project Tracker.
- `network:host:<hostname>` — explicit remote host allowlist.
- `filesystem:plugin-storage` — read/write only under `~/.holoscape/plugins/<storageNamespace>/` or equivalent `$HOLOSCAPE_CONFIG_DIR/plugins/<storageNamespace>/`.
- `filesystem:read-user-selected` — user-picked documents only, via explicit open panel grant.
- `notifications:plugin` — optional plugin notifications routed through Holoscape notification policy.
- `automation:apple-events` — future-only; must not be granted by default.

Core must not pass inherited shell/agent environment wholesale to plugins. Plugin runtime environment should contain only Holoscape-provided paths, declared config, and explicit credentials references.

## Storage ownership

Core storage and plugin storage are separate:

| Owner | Path family | Contains |
| --- | --- | --- |
| Core | `config.json`, broker registry, channel state, scrollback, crash reports | Terminal-critical state |
| Plugin manager | plugin enablement and validated manifest cache | Plugin registry metadata |
| Plugin | `plugins/<storageNamespace>/...` | Plugin cache, external ids, local indices |

A disabled plugin may leave plugin-owned storage on disk, but its data must not be read by core to render terminal/session state. Uninstall/prune UI should delete only that plugin namespace.

## Failure behavior

Plugin failures are scoped:

- Manifest validation failure: plugin never starts; diagnostics name the invalid field.
- Permission denial: plugin starts only if the missing permission is optional; otherwise it is disabled with a visible error.
- Runtime crash: plugin is marked `error`, contributions are removed or frozen, core terminal sessions continue.
- External service unavailable: plugin marks its channels/status as stale/error through plugin-owned state; core channels do not become stale unless their own broker/process state requires it.
- Slow plugin: core startup and channel switching must not wait on plugin network calls.

No plugin may install a silent fallback that changes core behavior. Example: if Project Tracker is down, Holoscape must not switch to a hidden local Kanban implementation inside core; it should show the plugin as unavailable and keep terminal functionality intact.

## UI contribution points

Initial contribution points should be append-only and removable:

1. **Session launcher profiles** — plugin-provided channel types appear below core Shell/Agent entries and disappear when disabled.
2. **Sidebar badges/supplemental text** — plugin status can add a secondary badge, but core persistent channel state has priority.
3. **Command palette/menu actions** — plugin commands are namespaced by plugin display name.
4. **Notification events** — plugin notifications route through `NotificationService` policy and can be muted per plugin.
5. **Diagnostics pane** — plugin health, manifest validation errors, permission denials, and last failure.

Plugins do not own the main terminal renderer, broker coordinator, core tab order, or core recovery actions.

## First-party Project Tracker plugin constraints

The eventual Project Tracker plugin may:

- create optional Project Tracker message-board channels;
- show task/handoff status as supplemental context;
- open Project Tracker URLs or local commands from explicit user actions;
- use `network:localhost` for the MacBook/dev tracker endpoint when configured.

It must not:

- make the Kanban board required for Holoscape launch;
- write Project Tracker ids into core broker/session records as required fields;
- block shell/agent channel creation when PT is unreachable;
- own handoff semantics inside core channel lifecycle;
- query PT from core startup code.

## Test targets for implementation

When this architecture moves from document to code, add deterministic tests for:

1. Core app/service initialization with zero installed plugins.
2. Manifest validation rejects unknown capability and permission names before plugin start.
3. Plugin storage namespace cannot collide with core stores.
4. Disabling a plugin removes launcher profiles, commands, badges, and notifications without touching core channels.
5. Plugin runtime crash leaves shell/agent/broker sessions running.
6. Project Tracker plugin unavailable state does not affect core terminal readiness.
7. Plugin status updates cannot overwrite higher-priority core error/stale channel state.

## Code substrate

The first implementation slice lives in:

- `Sources/Holoscape/Services/PluginManifest.swift` — closed capability/permission enums, manifest decoding, and deterministic validation before plugin start.
- `Sources/Holoscape/Services/ProjectTrackerPlugin.swift` — bundled first-party Project Tracker plugin descriptor. It declares optional channel, command, and status-adapter capabilities plus only `network:localhost` and plugin-storage permissions.
- `Tests/HoloscapeTests/Unit/PluginManifestTests.swift` — regression coverage that core can run with zero plugins, rejects unknown manifest fields before start, prevents core storage namespace collisions, and validates the bundled Project Tracker descriptor.

This slice intentionally does not start a Project Tracker client, query PT from app startup, or make any plugin required for terminal/channel launch.

## Board outcome

#7173 can be closed after this architecture definition is committed and the repository test/build baseline still passes, because the card’s deliverable is a removable plugin architecture with lifecycle, permissions, storage ownership, failure behavior, UI contribution points, and Project Tracker boundary rules documented before implementation.
