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

Codex/OpenClaw-style callers can use the same endpoint and add the tool/reason fields:

```json
{
  "tool": "codex",
  "type": "awaiting_approval",
  "cwd": "/Users/erik/projects/foo",
  "reason": "Codex is waiting for command approval"
}
```

`HoloscapeAPIServer` resolves the channel by `cwd`, updates the legacy notification
color path, applies the adapter state to agent channels, and lets `ChannelManager`
persist that state without changing the underlying process lifecycle.

## Clearing precedence

Adapter state can temporarily override the persisted UI state while the process is
still active. Broker/process failures clear adapter state and take precedence, so a
real stale/error lifecycle cannot be hidden by a stale external hook event.
