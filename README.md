# Holoscape

Native macOS terminal that replaces iTerm and Warp. Manages shell sessions, AI agent conversations, SSH connections, and group chat in one window with visual identity per channel.

## Quick Start

```bash
# Build and run
make run

# Or step by step:
./bundle.sh            # Build .app bundle (debug)
open build/Holoscape.app
```

## Documentation map

- [`PRD.md`](PRD.md) — current product behavior and explicitly future work.
- [`DECISIONS.md`](DECISIONS.md) — canonical architecture and reliability
  invariants.
- [`SETUP.md`](SETUP.md) — first-run, permissions, diagnostics, and recovery.
- [`docs/scrollback-history-persistence.md`](docs/scrollback-history-persistence.md)
  — broker scrollback retention, replay, and privacy contract.
- [`docs/agent-status-adapters.md`](docs/agent-status-adapters.md) — external
  status-event and process-ownership contract.
- [`docs/plugin-architecture.md`](docs/plugin-architecture.md) — optional plugin
  boundary and Project Tracker isolation.

Historical plans and audits under `docs/archive/` and `claude-specs/archive/`
are evidence only and do not define current behavior.

## Setup Claude Code Integration

```bash
make setup
```

This registers the MCP server and notification hooks so Claude Code can open tabs, send input, read output, and show notification colors in Holoscape.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+N | New session (launcher) |
| Cmd+W | Close channel |
| Cmd+1-9 | Switch to channel by position |
| Cmd+D | Split pane horizontal |
| Cmd+Shift+D | Split pane vertical |
| Cmd+Shift+W | Close split pane |
| Cmd+Shift+S | Toggle sidebar |
| Cmd+T | Toggle timestamps |
| Cmd+, | Settings |

Right-click any sidebar entry for: Close, Rename, Duplicate, Reconnect, Pin/Unpin, Copy Session Info.

## Channel Types

| Type | What it does |
|------|-------------|
| **Shell** | Local zsh in a broker-owned PTY, rendered by SwiftTerm |
| **Agent (OAuth)** | Broker-owned Claude Code session with OAuth auth (clean env, no API key leak) |
| **Agent (API Key)** | Broker-owned Claude Code session with ANTHROPIC_API_KEY injected |
| **SSH** | Remote terminal via SSH |
| **Group Chat** | Multi-agent chat via HTTP polling |
| **Bridge** | Broadcast channel to all agents |
| **MCP** | Client channel connected to an external Model Context Protocol server; distinct from the `HoloscapeMCP` control server |

## Running Tests

```bash
# Unit + property tests
make test

# Full UI test suite (~80 min, 350 tests across 10 shards)
make test-ui

# Quick smoke test (~5 min)
make test-ui-fast

# Single shard
make test-ui-shard SHARD=3

# Specific test class
make test-class CLASS=KeyboardShortcutsUITests

# Resume from last failed shard
make test-ui-resume
```

Results go to `/tmp/holoscape-test-shards/shard-{1..10}.txt` and `.xcresult` bundles.

**Note:** UI tests require macOS Accessibility/Automation permission for the test runner. Each `build-for-testing` re-signs the binary, which can invalidate the TCC grant — you may need to re-approve the system prompt.

## Configuration

App config lives in `~/.holoscape/` (or `$HOLOSCAPE_CONFIG_DIR` if set):

```
~/.holoscape/
  config.json          # Appearance, channels, SSH defaults
  skins/               # Color theme directories (each with skin.json)
  history-buffer.json  # Command/channel/settings/error history
  scrollback/          # Bounded broker-session output used for reattach replay
  pending-reports/     # Unsent bug reports
```

Local shell and agent processes are owned by the broker host rather than by a
tab view. They can survive GUI quit/relaunch and reattach through durable broker
session IDs. SSH restores by reconnecting; it does not claim to preserve the
remote PTY.

## Local API server

Holoscape runs a loopback-only HTTP server (default port 7865) for trusted local
MCP and hook integration:

```
GET  /channels                    # List all channels
POST /channels                    # Create channel (JSON: type, dir, label, cmd)
POST /channels/{id}/switch        # Switch to channel
POST /channels/{id}/input         # Send text input
GET  /channels/{id}/output?lines= # Read terminal output
DELETE /channels/{id}             # Close channel
POST /notify                      # Send notification (type, cwd)
```

Use `--api-port <PORT>` to change the port.

`HoloscapeMCP` is a separate newline-delimited stdio MCP server. Its
channel-control tools use this loopback API; its file, search, process, and
AppleScript tools execute locally in the MCP server process with the invoking
user's privileges. It controls HoloScape; it is not an MCP client channel or a
cloud service.

## Build

Requires macOS 15+ and Swift 6.0+.

Fresh clones must initialize the shader compiler vendor submodules before building:

```bash
git submodule update --init --recursive
```

The Makefile checks this before build/test targets and fails with that exact command if the submodules are missing.

```bash
make build            # Debug build
make bundle           # Debug .app bundle
make bundle-release   # Release .app bundle
make clean            # Remove build artifacts
```

Dependencies (resolved via Swift Package Manager):
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation
- [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) — MCP protocol (HoloscapeMCP target only)
- [SwiftCheck](https://github.com/typelift/SwiftCheck) — property-based testing

## Project Structure

```
Sources/
  Holoscape/           # Main app (AppKit, ~6k LOC)
    Controllers/       # Channel controllers, MainWindowController
    Services/          # Config, API server, notifications, skin engine
    Views/             # Sidebar, tab bar, split panes, terminal view
    Models/            # Channel types, config, profiles
    Protocols/         # ChannelController delegate
  HoloscapeMCP/        # MCP server binary (stdio transport)

Tests/
  HoloscapeTests/      # Unit tests
  HoloscapePropertyTests/ # Property-based tests (SwiftCheck)
  HoloscapeUITests/    # UI tests (350 tests, 30 classes)

scripts/
  test-ui-shards.sh    # Sharded test runner
  setup.sh             # Claude Code MCP + hooks registration
  notify-hook.sh       # Notification hook script
```
