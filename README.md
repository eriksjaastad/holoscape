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
| **Shell** | Local zsh terminal (PTY via SwiftTerm) |
| **Agent (OAuth)** | Claude Code session with OAuth auth (clean env, no API key leak) |
| **Agent (API Key)** | Claude Code session with ANTHROPIC_API_KEY injected |
| **SSH** | Remote terminal via SSH |
| **Group Chat** | Multi-agent chat via WebSocket API |
| **Bridge** | Broadcast channel to all agents |
| **MCP** | Model Context Protocol server connection |

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
  history-buffer.json  # Terminal scrollback history
  pending-reports/     # Unsent bug reports
```

## API Server

Holoscape runs a local HTTP server (default port 7865) for MCP and hook integration:

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

## Build

Requires macOS 15+ and Swift 6.0+.

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
