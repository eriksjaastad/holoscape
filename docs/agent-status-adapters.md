# Agent status adapters

Holoscape treats agent CLI status as product state, not as Claude-specific UI state.
External tools should report lifecycle events through the same adapter contract and let
Holoscape map them into `PersistentChannelState`.

## Supported tools

`AgentStatusAdapter` normalizes these tool identifiers today:

- `claude`, `claude-code`, `claude_code`
- `codex`, `codex-cli`, `codex_cli`
- `openclaw`, `open-claw`, `open_claw`
- unknown tools as `generic`

Unknown tool names are accepted, but unknown event names are ignored instead of
inventing state.

## Event mapping

| Adapter event aliases | Persistent state |
| --- | --- |
| `running`, `busy`, `started`, `response_started`, `task_started` | `running` |
| `ready`, `idle`, `idle_prompt`, `response_completed`, `turn_complete`, `task_complete` | `ready` |
| `needs-approval`, `needs_approval`, `permission_prompt`, `approval_prompt`, `user_decision`, `awaiting_approval` | `needs-approval` |
| `error`, `failed`, `failure`, `exception` | `error` |
| `stale`, `detached`, `session_stale`, `session-missing`, `session_missing` | `stale` + recreate recovery |

## HTTP notify path

Existing Claude hook posts still work:

```json
{"type":"permission_prompt","cwd":"/Users/erik/projects/foo"}
```

Holoscape-launched agents also inherit `HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN`.
Status hooks must echo it as `ownerToken`. Holoscape persists this non-secret
generation token with broker session metadata, so reattached tabs retain exact
process ownership after an app relaunch. Fresh processes reject unscoped, stale,
or foreign-token events. Legacy broker records created before token persistence
accept only tokenless hooks and only when the working directory identifies one
eligible channel unambiguously; they never adopt an arbitrary scoped token.

Codex/OpenClaw-style callers can use the same endpoint and add the tool/reason fields:

```json
{
  "tool": "codex",
  "type": "awaiting_approval",
  "cwd": "/Users/erik/projects/foo",
  "ownerToken": "value inherited from HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN",
  "reason": "Codex is waiting for command approval"
}
```

`HoloscapeAPIServer` resolves scoped events by `cwd` plus exact process owner,
updates the legacy notification color path, applies the adapter state to agent
channels, and lets `ChannelManager` persist that state without changing the
underlying process lifecycle. A scoped event never falls back to a shell or a
different same-directory agent.

## Clearing precedence

Adapter state can temporarily override the persisted UI state while the process is
still active. Broker/process failures clear adapter state and take precedence, so a
real stale/error lifecycle cannot be hidden by a stale external hook event.
Each status source owns a separate state slot: adapter updates clear only adapter
state, terminal input clears only terminal-output state, and plugin updates clear
only plugin state. Process teardown does not discard plugin-owned failures.
