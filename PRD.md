# PRD: Holoscape Native Terminal

## Overview

Holoscape is a native macOS terminal application that replaces iTerm/Warp with a channel-based interface for managing multiple AI agent conversations, local shell sessions, and remote connections in one window. This is a ground-up native rebuild of the existing Electron-based Holoscape chat client — same vision (skinnable AI interface), better foundation (Swift/AppKit), expanded scope (terminal + chat).

Mini Claude on the Mac Mini is the dev team. Erik directs. Agents build.

## Goals

- Erik never accidentally sends a message to the wrong agent again
- Every active connection (agent, shell, SSH, group chat) is visible and identifiable at a glance
- Text input works like a normal text editor — click to position cursor, select text, delete
- Agent conversations and shell sessions coexist in the same application
- OAuth and API key auth are isolated per channel — no billing accidents
- Bug reports and crash data flow automatically to Mini Claude for triage
- The terminal is 100% owned — customizable, extensible, no third-party dependency

## Non-Goals

- Cross-platform support (macOS only)
- Selling or distributing Holoscape
- Replacing Claude Code itself (Holoscape hosts Claude Code sessions)
- Full Winamp skin engine in V1 (color themes + transparency first)
- Chat bubble rendering (terminal-style output for everything)
- Plugin/extension marketplace
- Mobile or iPad version

## Target Users

Erik Sjaastad — sole user. Manages 4+ AI agent sessions simultaneously across two machines (MacBook + Mac Mini). Currently uses iTerm and Warp with no visual distinction between windows.

## Problem Statement

Managing multiple agent conversations in identical-looking terminal windows causes constant confusion. In a single session on 2026-04-03, Erik sent messages to the wrong agent at least 3 times, confused which window was which, and lost track of what each agent was working on. Every terminal window looks the same — same font, same black background, same prompt. There's no awareness of what's happening across sessions, no unread indicators, no role labels, no identity.

The secondary problem: existing terminals are someone else's product. They can't connect to a custom agent chat API, they don't understand OAuth vs API key isolation, and they can't be customized beyond themes. In 2026, there's no reason to accept these limitations when agents can build a custom terminal in a sprint.

## Core Concept / Data Model

**Channels** are the core abstraction. A channel is a named, typed connection to a backend:

| Channel Type | Backend | Protocol | Auth |
|-------------|---------|----------|------|
| Shell | Local zsh | PTY (SwiftTerm) | User's default env |
| Agent (direct) | Claude Code process | PTY (SwiftTerm) | OAuth (clean env, no API key) |
| Agent (API) | Claude Code process | PTY (SwiftTerm) | API key injected |
| Agent (SSH) | Remote claude on Mac Mini | SSH PTY | SSH key + OAuth on Mini |
| Group Chat | Agent Chat API (Cloud Run) | WebSocket/HTTP polling | X-API-Key header |

**Channel identity** is derived from:
- **Type** (shell, agent, group chat)
- **Role** (Architect, Floor Manager, CEO) — detected from working directory CLAUDE.md or user-assigned at creation
- **Context** (project directory for floor managers, machine name for SSH)
- **Instance number** (auto-assigned when multiple of same role: AR1, AR2)

**Auth isolation** is per-channel:
- Each channel spawns its process in a clean environment
- OAuth channels: ANTHROPIC_API_KEY is explicitly UNSET
- API channels: ANTHROPIC_API_KEY is injected from secure storage
- Keys never leak between channels

**Bug reports** are a simple data object:
- Channel name, channel type, last 20 lines of output, timestamp, macOS version, user description
- No API keys, no conversation content, no sensitive data
- POSTed to Synth Insight Labs REST endpoint
- Crash traces pulled from ~/Library/Logs/DiagnosticReports/

## Functional Requirements

### Channel Management
- Create new channels of any type (shell, agent, group chat)
- Close channels (with confirmation if process is running)
- Switch between channels via tab bar
- Auto-number duplicate role channels (AR1, AR2)
- Unread indicator (dot) on tabs with new content since last viewed
- Unread channels bump to the left of the tab bar
- Channel state persists across app restarts (which channels were open, their type and role)

### Terminal Emulation
- Full ANSI/VTE escape code support (via SwiftTerm)
- Local shell via PTY (via SwiftTerm LocalProcessTerminalView)
- Scrollback buffer (configurable depth)
- Standard terminal capabilities (cursor positioning, colors, alternate screen)

### Text Input
- NSTextView-based input at bottom of window
- Click anywhere to position cursor
- Select text with mouse or Shift+Arrow
- Delete/Backspace on selections
- Cmd+A, Cmd+C, Cmd+V, Cmd+X
- Enter to send/execute
- Up/Down arrow for command history (per channel)

### Agent Integration
- Spawn `claude` CLI process in a PTY with environment isolation
- Detect role from CLAUDE.md in working directory OR user-assigned label
- Display role prominently on channel tab
- Floor manager channels show project directory name

### Group Chat
- Connect to agent chat API (Cloud Run) via HTTP polling or WebSocket
- Display messages with sender labels and timestamps: `[8:15 PM] architect: message`
- Send messages as "erik" sender
- Show messages from all participants (erik, claude-architect, mini-claude, ceo)
- Unread indicator when new messages arrive while viewing another channel

### Bug Reporting
- Cmd+B opens one-line input overlay
- User types description, Enter to submit
- Auto-attaches: channel name, channel type, last 20 lines of output, timestamp, macOS version
- POSTs to Synth Insight Labs API endpoint
- On launch: scan ~/Library/Logs/DiagnosticReports/ for Holoscape crash logs since last launch
- If crash found: prompt "Holoscape crashed. File a report?" with one-click submit
- Crash report includes full crash trace + last channel state before crash

### Appearance
- Background color picker
- Transparency slider
- Font family and size selector
- ANSI color palette customization
- Settings persist to ~/.holoscape/config.json

## Non-Functional Requirements

- **Startup:** Under 2 seconds to usable window
- **Channel switching:** Instant (no re-rendering delay)
- **Terminal rendering:** Match or exceed iTerm performance (SwiftTerm handles this)
- **Memory:** Each channel is an independent process — closing a channel frees its memory
- **Crash resilience:** App crash doesn't kill running agent processes (they're separate PIDs)
- **No telemetry:** No analytics, no phone-home, no tracking. Erik's terminal, Erik's data.

## UX and UI Requirements

### Window Layout
- Single window application (not multi-window)
- Tab bar across top: scrollable, shows channel labels with role + context
- Terminal output area: full width, standard monospace rendering
- Input box at bottom: NSTextView with real text editing
- No sidebar in V1 (V2 feature)

### Tab Bar
- Each tab: role label + unread dot
- Format: "Shell", "Architect", "FM-tracker", "CEO", "Group", "AR2"
- Unread tabs show a dot indicator
- Unread tabs bump to left of tab bar
- Scrollable when many tabs open
- Click to switch, Cmd+W to close

### Visual Identity
- Each channel type could have a subtle color accent on its tab (shell=green, agent=blue, group=purple) — defer to implementation
- Active tab is visually distinct from inactive
- Semi-transparent window support (macOS native transparency)

### Group Chat Rendering
- Terminal-style monospace, not chat bubbles
- Format: `[HH:MM PM] sender: message body`
- Sender labels in brackets, consistent formatting
- Scrollback like any other terminal channel

## Success Metrics

- Erik stops mixing up agent windows (primary — qualitative, self-reported)
- Bug reports flow from Holoscape to Mini Claude without manual intervention
- Channel switching is instant and identity is unambiguous
- Text input feels like a normal text editor, not a 1970s terminal
- Holoscape becomes Erik's primary terminal within 1 week of V1

## Session Launcher

The primary way to open new sessions. Replaces the Cmd+N modal picker with a smarter, profile-driven launcher.

### Session Profiles

A session profile defines everything needed to open a connection in one click:

| Field | Description |
|-------|-------------|
| label | Tab display name (e.g., "mini-claude", "architect", "holoscape") |
| connection | `local` (PTY on this machine) or `ssh` (SSH to remote host) |
| host | SSH hostname (e.g., MacBook.local) — only for SSH connections |
| user | SSH username — only for SSH connections |
| directory | Working directory on the target machine |
| command | What to run: `claude` or `/bin/zsh` |

**Preconfigured sessions (from config):**

| Session | Connection | Directory | Command | Notes |
|---------|-----------|-----------|---------|-------|
| mini-claude | local | `~` | `claude` | This machine's local Claude agent |
| architect | ssh → MacBook | `~/projects` | `claude` | The Architect agent on Erik's laptop |
| shell | local | `~` | `/bin/zsh` | Plain local terminal |

**Auto-discovered sessions:** Holoscape scans a configurable `project_root` on the MacBook (via SSH) to discover project directories. Each project directory becomes a launchable session that opens a floor manager Claude agent in that directory. Example: `~/projects/holoscape/` → session labeled "holoscape".

### Session Opener UI

- **Location:** Button at the top of the left sidebar ("Open Session" or "+" icon)
- **Behavior:** Click → dropdown/combobox appears
- **Dropdown contents:**
  - Preconfigured sessions (mini-claude, architect, shell, etc.)
  - Auto-discovered project sessions
  - Recently used sessions (sorted by recency)
- **Combobox:** The dropdown is editable — Erik can type over it to enter a new project name or custom path. Typing a new name opens a floor manager `claude` session in `~/projects/<typed-name>/` on the MacBook.
- **One-click launch:** Selecting any item immediately opens the session and creates a tab.

### Session Config Format

Stored in `~/.holoscape/config.json` alongside appearance and channel state:

```json
{
  "session_profiles": [
    {"label": "mini-claude", "connection": "local", "command": "claude", "directory": "~"},
    {"label": "architect", "connection": "ssh", "host": "MacBook.local", "user": "erik", "command": "claude", "directory": "~/projects"},
    {"label": "shell", "connection": "local", "command": "/bin/zsh", "directory": "~"}
  ],
  "ssh_defaults": {
    "host": "MacBook.local",
    "user": "erik"
  },
  "project_discovery": {
    "enabled": true,
    "root": "~/projects",
    "connection": "ssh",
    "command": "claude"
  }
}
```

## Collapsible Sidebar

### Default: Left sidebar with tabs

- Tabs are displayed vertically in a left sidebar panel
- Each tab shows: role label, unread dot, connection status
- Sidebar is scrollable when many tabs are open
- Active tab is visually distinct
- Unread tabs auto-move to the top of the sidebar and are highlighted

### Collapsed: Top tab bar

- A toggle button (or drag handle) collapses the sidebar
- When collapsed, tabs shift to a horizontal bar across the top of the window (current behavior)
- The top bar is scrollable when tabs overflow
- Sidebar state (open/collapsed) persists across restarts

### Right-Click Context Menu on Tabs

Right-clicking any tab (sidebar or top bar) opens a context menu:

- **Close** — close this tab (with confirmation if process is running)
- **Rename** — change the tab's display label
- **Duplicate** — open a new session with the same profile
- **Reconnect** — restart a disconnected session
- **Copy Session Info** — copy connection details to clipboard
- (More items can be added as needed — the menu is defined in one place)

## V2 Features

### CEO Connection via MCP Bridge

Holoscape connects directly to the Auxesis CEO agent for bidirectional communication. This is similar to how OpenClaw used MCP (Model Context Protocol) connections for Discord/Slack — a structured message bridge between Holoscape and a specific agent role in the Auxesis pipeline.

**How it works:**
- Auxesis exposes the CEO role via an MCP server endpoint (HTTP or stdio)
- Holoscape acts as an MCP client, connecting to the CEO's endpoint
- Messages sent from the Holoscape CEO tab are delivered to the Auxesis CEO agent
- Responses from the CEO agent appear in the Holoscape CEO tab
- The CEO tab renders messages in terminal-style format: `[HH:MM PM] CEO: message body`

**Connection config** (in session profiles):
```json
{"label": "CEO", "connection": "mcp", "endpoint": "http://localhost:8080/mcp/ceo"}
```

**What Auxesis needs to expose:**
- An MCP server that routes messages to/from the CEO role
- This could be a new endpoint on the Auxesis sidecar (already running on the Mac Mini)
- Or a standalone MCP server process that bridges to Auxesis's internal messaging

**What Holoscape needs:**
- A new `MCPChannelController` that implements the MCP client protocol
- Renders incoming messages in the terminal view
- Sends outgoing messages via MCP tool calls or message protocol
- Handles connection/disconnection gracefully (same pattern as SSH channels)

### Group Chat Channel

Connect to the Agent Chat API (existing Flask app on Cloud Run) for multi-participant messaging. This was originally in V1 scope but deferred.

**How it works:**
- Holoscape connects to the Agent Chat API via HTTP polling (poll every 2-3 seconds for new messages)
- Messages rendered in terminal-style monospace: `[HH:MM PM] sender: message body`
- Erik sends messages as "erik" sender
- Displays messages from all participants: erik, claude-architect, mini-claude, ceo
- Unread indicator when new messages arrive while viewing another channel

**Connection config:**
- API URL and API key loaded from `~/.claude/agent-chat.env` (existing config)
- Or stored in session profile: `{"label": "Group Chat", "connection": "agent-chat", "api_url": "...", "api_key_env": "AGENT_CHAT_API_KEY"}`

**Rendering:**
- Uses a custom read-only NSTextView (monospace) — NOT SwiftTerm, since there's no PTY
- Messages appended as they arrive, with scrollback buffer
- Auto-scroll to bottom on new messages unless Erik has scrolled up

### Running Process Indicator

Each tab shows whether its backend process is running, and for how long.

- **Active channels** show a green dot + elapsed time since activation (e.g., "Shell (2h 15m)")
- **Disconnected channels** show a red dot + "disconnected"
- **Connecting channels** show a yellow dot + "connecting..."
- Elapsed time updates every minute (not every second — avoid unnecessary redraws)
- Displayed in both the sidebar tab entries and the horizontal tab bar

### Timestamps on Terminal Output

Toggle-able timestamps prepended to every line of terminal output.

- When enabled, each line of output gets a `[HH:MM:SS]` prefix in a dimmed color
- Toggle via menu: View > Show Timestamps (Cmd+T)
- Setting persists to config
- Applies to all channel types (shell, agent, SSH, group chat, CEO)
- Timestamps are local time
- For group chat, the existing `[HH:MM PM] sender:` format remains — the timestamp toggle adds seconds precision

### Color Theme Presets

Pre-built color themes that set background color, text color, and ANSI color palette in one click.

- **Dark (default):** Current dark blue/purple theme (#1a1a2e background)
- **Monokai:** Dark background with Monokai ANSI colors
- **Solarized Dark:** Solarized color scheme
- **Solarized Light:** Light background variant
- **Dracula:** Popular dark theme
- **Nord:** Nordic blue-gray theme

**UI:** Settings panel gets a theme dropdown. Selecting a theme applies all colors at once. Individual color settings still override theme values.

**Config:** Theme name stored in appearance config. Custom overrides stored separately.

### Keyboard Shortcuts for Channel Switching

Quick-switch between the first 9 channels using Cmd+1 through Cmd+9.

- **Cmd+1** switches to the first channel in tab order
- **Cmd+2** switches to the second, etc.
- **Cmd+9** switches to the ninth
- Tab order matches the sidebar (or horizontal tab bar when collapsed)
- Shortcuts are always active regardless of sidebar state
- If fewer than N channels exist, Cmd+N (where N > channel count) does nothing

## V3 Features

### Desktop Notifications for Unread Channels

When Holoscape is not the frontmost app and a channel receives new content, show a macOS notification.

**How it works:**
- Uses `UNUserNotificationCenter` for native macOS notifications
- Notification shows: channel label, first line of new content (truncated to 100 chars)
- Clicking the notification brings Holoscape to front and switches to that channel
- Notifications are only sent when Holoscape is NOT the active app (no notifications while focused)
- Notification grouping: one notification per channel, updated on subsequent messages (not spammed)
- Setting to enable/disable notifications per channel type (shell, agent, SSH, MCP, group chat)
- Global toggle: Settings > Notifications > Enable Desktop Notifications

**Config:**
```json
{
  "notifications": {
    "enabled": true,
    "perChannelType": {
      "shell": false,
      "agent": true,
      "ssh": true,
      "mcp": true,
      "groupChat": true
    }
  }
}
```

### Window Splitting (Side-by-Side Channels)

View two channels simultaneously in a split terminal area.

**How it works:**
- **Cmd+D** splits the terminal area horizontally (left/right)
- **Cmd+Shift+D** splits vertically (top/bottom)
- Each split pane shows a different channel's content view
- The active pane has a subtle border highlight
- Click a pane to make it active — input goes to the active pane's channel
- **Cmd+Shift+W** closes the current split pane (returns to single view)
- Maximum 4 panes (2x2 grid)
- Split state persists across restarts

**Implementation:**
- Replace the single `TerminalContainerView` with an `NSSplitView` that can be recursively split
- Each split pane wraps a channel's content view
- The active pane ID is tracked separately from the sidebar selection

### Bridge Channel (Broadcast to All Agents)

A special channel type that sends messages to ALL open agent channels simultaneously.

**How it works:**
- Bridge channel appears in the session launcher as a preconfigured option
- When Erik types in the bridge channel and hits Enter, the message is sent to every active agent channel (Agent Direct, Agent API, SSH running claude, MCP)
- Shell channels are excluded (not agents)
- Group chat channels are excluded (not agents)
- Responses appear in each individual agent's channel, not in the bridge
- The bridge channel's content view shows a log of what was broadcast: `[H:MM PM] → broadcast: message`
- Useful for: "everyone stop what you're doing", "status report from all agents", "new priority"

**Connection config:**
```json
{"label": "Bridge", "connection": "bridge"}
```

### Tab Pinning

Pin important tabs so they don't move when other channels get unread indicators.

**How it works:**
- Right-click a tab → "Pin" (added to context menu)
- Pinned tabs stay at the top of the sidebar / left of the tab bar
- Pinned tabs show a small pin icon next to the label
- Unread reordering only affects unpinned tabs
- Pinned tabs are ordered by pin time (first pinned = first position)
- "Unpin" option in right-click menu to remove the pin
- Pin state persists in channel metadata

### Search Across Channel Output (Cmd+F)

Search the scrollback buffer of the active channel.

**How it works:**
- **Cmd+F** opens a search bar at the top of the terminal area (below the tab bar)
- Type to search — matches highlighted in the scrollback
- **Enter** or **Cmd+G** jumps to next match
- **Cmd+Shift+G** jumps to previous match
- **Escape** closes the search bar
- Search applies to the active channel only
- For PTY channels (SwiftTerm): search the terminal buffer text
- For NSTextView channels (MCP, group chat): search the text storage

### Winamp-Style Skin Engine

Fully customizable window chrome and UI elements via skin packages.

**How it works:**
- A skin is a directory containing: `skin.json` (layout + color definitions) and image assets (PNG)
- `skin.json` defines: window background, title bar, sidebar background, tab active/inactive colors, button images, border styles, font overrides
- Skins are loaded from `~/.holoscape/skins/<skin-name>/`
- Settings panel gets a skin picker dropdown (similar to theme picker but more comprehensive)
- Default skin is the built-in Dark theme
- Community skins can be shared as zip files

**This is a large feature — defer detailed design until V3 implementation.**

## MVP Scope

**V1 — SHIPPED:**
- Native macOS window with SwiftTerm
- Top tab bar for channels with role labels and unread indicators
- Shell channel (local zsh with real text editing input)
- Agent channel (spawn claude process with auth isolation)
- Cmd+B bug reporting with SIL API integration
- Crash detection and one-click reporting on launch
- Background color, transparency, font settings
- Channel state persistence across restarts

**V1.5 — SHIPPED:**
- Session launcher with profile-driven combobox opener
- SSH agent channel (SSH → remote machine → run claude)
- Auto-discovery of project directories on MacBook
- Left sidebar tab panel (collapsible → falls back to top bar)
- Right-click context menu on tabs (close, rename, duplicate, reconnect)
- Consistent instance numbering (mini-claude 1, mini-claude 2 — both numbered)
- Directory-based tab labeling for SSH project sessions

**V2 — SHIPPED:**
- CEO connection via MCP bridge to Auxesis (MCPClient actor + MCPChannelController)
- Group chat channel (Agent Chat API via HTTP polling, custom NSTextView, auto-scroll)
- Running process indicator with elapsed time on tabs (green/yellow/red dots + "2h 15m")
- Timestamps on terminal output (toggle via Cmd+T, [HH:MM:SS] prefix)
- Color theme presets (Dark, Monokai, Solarized Dark/Light, Dracula, Nord) with override support
- Cmd+1-9 keyboard shortcuts for channel switching via NSEvent local monitor

**V3 — Next sprint:**
- Desktop notifications for unread channels (macOS UNUserNotificationCenter)
- Window splitting (side-by-side channels in the terminal area)
- Bridge channel (broadcast a message to all open agent channels simultaneously)
- Tab pinning (pin important tabs so they don't reorder on unread)
- Search across channel output (Cmd+F to search scrollback in active channel)
- Full Winamp-style skin engine (custom window chrome, skinnable UI elements)

**V4 — Someday:**
- Plugin/extension model
- Scriptable actions (AppleScript or custom scripting for automation)
- Multi-window support (detach a channel into its own window)

## Constraints / Technical Stack

- **Language:** Swift
- **UI Framework:** AppKit (not SwiftUI — need NSTextView control)
- **Terminal Emulation:** SwiftTerm (github.com/migueldeicaza/SwiftTerm)
- **Minimum macOS:** Sequoia (15.0)
- **Build System:** Xcode / Swift Package Manager
- **No Electron, no web engine, no JavaScript**
- **Bug report API:** Synth Insight Labs REST endpoint (new, needs building)
- **Agent chat API:** Existing Flask app on Cloud Run (project-tracker/agent-chat/)
- **Auth:** Agent chat API key via X-API-Key header. Claude OAuth vs API key isolated per channel.
- **Dev team:** Mini Claude (Mac Mini). Erik directs.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| ~~SwiftTerm + group chat~~ | — | — | **RESOLVED (V2):** Group chat uses custom NSTextView, not SwiftTerm. Works cleanly. |
| ~~SSH PTY latency~~ | — | — | **RESOLVED (V1.5):** SSH via system `ssh` binary + SwiftTerm PTY works well. |
| UNUserNotificationCenter permission denied | Low | Medium | Request permission on first launch. Gracefully degrade if denied — no notifications, no crash. |
| NSSplitView recursive splitting for window split | Medium | Medium | Test with 2-pane first. 4-pane (2x2) may need custom layout. Defer 4-pane to V3.1 if complex. |
| Bridge channel message delivery order | Low | Medium | Send to all agents in tab order. No guarantee of simultaneous delivery — document this. |
| Skin engine scope creep | High | High | Define a minimal skin spec first (colors + images only). No layout changes in V3. Full layout engine deferred to V4. |
| Cmd+F search performance on large scrollback | Low | Medium | Limit search to last 10,000 lines. SwiftTerm buffer search may need custom implementation. |
| Crash report API on SIL needs to be built | Low | Low | Simple REST endpoint — POST to receive, GET to list. Could be a single Cloud Run function. |

## Open Questions

1. ~~How should channel creation work?~~ **ANSWERED:** Session launcher combobox.
2. ~~How does Holoscape detect roles?~~ **ANSWERED:** Labels from session profiles.
3. ~~What happens when a process dies?~~ **ANSWERED:** Disconnected state, manual retry.
4. ~~SSH key management?~~ **ANSWERED:** System SSH agent.
5. ~~Project directory discovery?~~ **ANSWERED:** SSH ls with cache.
6. ~~Group chat: WebSocket or HTTP polling?~~ **ANSWERED (V2):** HTTP polling, 3-second interval.
7. ~~Timestamps: intercept or overlay?~~ **ANSWERED (V2):** Intercept via output delegate for PTY, appendMessage for NSTextView.
8. What's the right data format for the SIL bug report API?
9. **V3:** Should desktop notifications use notification categories (actionable notifications with "Switch to Channel" button)?
10. **V3:** For window splitting, should the split state be per-workspace or global? (i.e., can different "layouts" be saved and restored?)
11. **V3:** For the bridge channel, should responses from agents be echoed back into the bridge view, or only in individual channels?
12. **V3:** For the skin engine, what's the minimum viable skin spec? Colors-only? Colors + images? Full layout?
