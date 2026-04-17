# Requirements Document — Holoscape V2 Features

## Introduction

Holoscape V2 is an incremental update to the existing Holoscape Native Terminal (V1 + V1.5). V1 provides local shell channels, agent channels (Claude CLI with auth isolation), bug reporting, crash detection, appearance settings, and channel state persistence. V1.5 adds SSH agent channels, a profile-driven session launcher, a collapsible sidebar, and right-click context menus. V2 adds six capabilities: CEO connection via MCP bridge, group chat channel via HTTP polling, running process indicators on tabs, toggleable timestamps on terminal output, color theme presets, and Cmd+1-9 keyboard shortcuts for channel switching.

This document specifies only the NEW requirements introduced in V2. All V1 and V1.5 requirements remain in effect and are not repeated here.

## Glossary

- **Holoscape**: The native macOS terminal application being specified
- **MCP**: Model Context Protocol — a structured message protocol for communication between AI agents and clients
- **MCP_Client**: The Holoscape-side implementation of the MCP protocol that connects to an MCP server endpoint
- **MCP_Channel**: A channel type that connects to an MCP server endpoint for bidirectional messaging with an AI agent (e.g., the Auxesis CEO)
- **MCPChannelController**: The controller class implementing the MCP client protocol and rendering messages in terminal-style format
- **CEO_Agent**: The Auxesis CEO role exposed via an MCP server endpoint
- **Group_Chat_Channel**: A channel type that connects to the Agent Chat API via HTTP polling for multi-participant messaging
- **Agent_Chat_API**: The existing Flask application on Cloud Run that provides the group chat messaging backend
- **Polling_Interval**: The time between consecutive HTTP requests to the Agent Chat API for new messages (2-3 seconds)
- **Process_Indicator**: A visual element on each tab showing the channel's connection state (active, disconnected, connecting) and elapsed time
- **Elapsed_Time**: The duration since a channel entered the active state, displayed in hours and minutes (e.g., "2h 15m")
- **Timestamp_Overlay**: An optional `[HH:MM:SS]` prefix prepended to each line of terminal output in a dimmed color
- **Color_Theme**: A named preset defining background color, text color, and ANSI color palette values applied as a unit
- **Theme_Override**: An individual color setting that takes precedence over the active Color_Theme value for that specific color
- **Config_File**: The JSON file at ~/.holoscape/config.json storing all Holoscape settings
- **Sidebar**: The collapsible left panel displaying open channels as a vertical tab list (from V1.5)
- **Tab_Bar**: The horizontal bar across the top of the window displaying open channels when the Sidebar is collapsed (from V1)
- **Channel_Manager**: The central registry that creates, tracks, closes, persists, and restores channels
- **SwiftTerm**: The open-source terminal emulation library used for PTY-based rendering
- **InputBox**: The NSTextView-based text input area at the bottom of the window
- **Session_Profile**: A configuration record defining everything needed to open a connection (from V1.5)

## Requirements

### Requirement 1: CEO Connection via MCP Bridge

**User Story:** As Erik, I want to communicate with the Auxesis CEO agent directly from a Holoscape tab, so that I can send directives and receive responses without leaving my terminal.

#### Acceptance Criteria

1. THE Session_Profile SHALL support a connection type of "mcp" with an endpoint field specifying the MCP server URL (e.g., `http://localhost:8080/mcp/ceo`).
2. WHEN a session with connection type "mcp" is launched, THE Holoscape SHALL create an MCPChannelController that establishes an MCP_Client connection to the configured endpoint.
3. WHEN the MCP_Client successfully connects to the MCP server endpoint, THE MCP_Channel SHALL transition to "active" state.
4. WHEN Erik types in the InputBox and presses Enter while an MCP_Channel is active, THE MCPChannelController SHALL send the input text to the CEO_Agent via the MCP protocol.
5. WHEN the MCP_Client receives a response from the CEO_Agent, THE MCPChannelController SHALL render the response in the content view in terminal-style format: `[HH:MM PM] CEO: message body`.
6. THE MCP_Channel SHALL use a read-only NSTextView with monospace font as its content view, matching the Group_Chat_Channel rendering approach.
7. IF the MCP_Client fails to connect to the MCP server endpoint, THEN THE MCP_Channel SHALL transition to "disconnected" state and display the failure reason in the content view.
8. IF an established MCP connection drops unexpectedly, THEN THE MCP_Channel SHALL transition to "disconnected" state and preserve the last output in the content view.
9. WHEN Erik triggers a retry on a disconnected MCP_Channel, THE MCPChannelController SHALL attempt to re-establish the MCP_Client connection to the configured endpoint.
10. THE MCP_Channel tab label SHALL display the Session_Profile label (e.g., "CEO") followed by the Instance_Number when applicable.

### Requirement 2: Group Chat Channel

**User Story:** As Erik, I want a group chat channel that connects to the Agent Chat API, so that I can see messages from all participants and send messages as myself in one shared conversation.

#### Acceptance Criteria

1. THE Session_Profile SHALL support a connection type of "agent-chat" with fields for api_url (string) and api_key_env (string referencing an environment variable name).
2. WHEN a session with connection type "agent-chat" is launched, THE Holoscape SHALL load the API key from the environment variable specified by api_key_env, or from `~/.claude/agent-chat.env` as a fallback.
3. WHEN the Group_Chat_Channel activates, THE Holoscape SHALL begin polling the Agent_Chat_API for new messages at a Polling_Interval of 2-3 seconds.
4. WHEN the Agent_Chat_API returns new messages, THE Group_Chat_Channel SHALL render each message in terminal-style monospace format: `[HH:MM PM] sender: message body`.
5. THE Group_Chat_Channel SHALL display messages from all participants without filtering (erik, claude-architect, mini-claude, ceo, and any other sender).
6. WHEN Erik types in the InputBox and presses Enter while a Group_Chat_Channel is active, THE Group_Chat_Channel SHALL POST the message to the Agent_Chat_API with "erik" as the sender field.
7. THE Group_Chat_Channel SHALL use a read-only NSTextView with monospace font as its content view — not SwiftTerm — since there is no PTY backend.
8. THE Group_Chat_Channel SHALL maintain a scrollback buffer of appended messages.
9. WHEN new messages arrive, THE Group_Chat_Channel SHALL auto-scroll to the bottom of the content view, unless Erik has manually scrolled up from the bottom.
10. WHEN new messages arrive on a Group_Chat_Channel that is not the currently active channel, THE Group_Chat_Channel SHALL set its unread indicator to true.
11. IF the Agent_Chat_API returns a 401 or 403 HTTP status, THEN THE Group_Chat_Channel SHALL display "Authentication failed. Check API key." and stop polling.
12. IF the Agent_Chat_API connection fails for a non-auth reason, THEN THE Group_Chat_Channel SHALL attempt reconnection with exponential backoff (1s, 2s, 4s, 8s, max 30s) and display "Reconnecting..." status.

### Requirement 3: Running Process Indicator

**User Story:** As Erik, I want each tab to show whether its backend process is running and for how long, so that I can see at a glance which sessions are active and how long they have been running.

#### Acceptance Criteria

1. WHILE a channel is in "active" state, THE Holoscape SHALL display a green dot indicator and the Elapsed_Time since the channel entered the active state (e.g., "Shell (2h 15m)") on the channel's tab entry.
2. WHILE a channel is in "disconnected" state, THE Holoscape SHALL display a red dot indicator and the text "disconnected" on the channel's tab entry.
3. WHILE a channel is in "connecting" state, THE Holoscape SHALL display a yellow dot indicator and the text "connecting..." on the channel's tab entry.
4. THE Elapsed_Time display SHALL update every 60 seconds.
5. THE Process_Indicator SHALL be displayed in both the Sidebar tab entries and the horizontal Tab_Bar entries.
6. WHEN a channel transitions from one state to another, THE Process_Indicator SHALL update immediately to reflect the new state.
7. WHEN a channel transitions to "active" state, THE Holoscape SHALL record the activation timestamp and begin computing Elapsed_Time from that moment.

### Requirement 4: Timestamps on Terminal Output

**User Story:** As Erik, I want to toggle timestamps on terminal output lines, so that I can see exactly when each line of output was produced.

#### Acceptance Criteria

1. WHEN the timestamp display is enabled, THE Holoscape SHALL prepend a `[HH:MM:SS]` prefix in local time to each line of terminal output in a dimmed (reduced opacity) color.
2. WHEN the timestamp display is disabled, THE Holoscape SHALL render terminal output without timestamp prefixes.
3. THE Holoscape SHALL provide a menu item at View > Show Timestamps with the keyboard shortcut Cmd+T to toggle the timestamp display on and off.
4. THE Holoscape SHALL persist the timestamp display setting to the Config_File and restore the setting on launch.
5. THE Timestamp_Overlay SHALL apply to all channel types: shell, agent (direct and API), SSH, MCP, and group chat.
6. WHEN the timestamp display is enabled on a Group_Chat_Channel, THE Holoscape SHALL add seconds precision to the existing `[HH:MM PM] sender:` format rather than prepending a separate timestamp prefix.
7. THE timestamps SHALL use the local time zone of the machine running Holoscape.

### Requirement 5: Color Theme Presets

**User Story:** As Erik, I want to select from pre-built color themes, so that I can change the entire look of Holoscape in one click instead of adjusting individual colors.

#### Acceptance Criteria

1. THE Holoscape SHALL include the following built-in Color_Themes: Dark (default), Monokai, Solarized Dark, Solarized Light, Dracula, and Nord.
2. EACH Color_Theme SHALL define values for: background color, text color, and the full ANSI color palette (16 colors: 8 standard + 8 bright).
3. THE Appearance settings panel SHALL display a theme dropdown allowing Erik to select a Color_Theme.
4. WHEN Erik selects a Color_Theme from the dropdown, THE Holoscape SHALL apply all color values defined by that theme to the terminal rendering and UI.
5. WHEN Erik modifies an individual color setting (background, text, or any ANSI color) after selecting a theme, THE Holoscape SHALL store that modification as a Theme_Override that takes precedence over the theme's value for that specific color.
6. THE Config_File SHALL store the active theme name in the appearance configuration and store Theme_Overrides separately from the theme selection.
7. WHEN Holoscape launches and loads a config with a theme name and Theme_Overrides, THE Holoscape SHALL apply the theme first and then apply the overrides on top.
8. WHEN Erik selects a new Color_Theme, THE Holoscape SHALL clear all existing Theme_Overrides so the new theme applies cleanly.

### Requirement 6: Keyboard Shortcuts for Channel Switching

**User Story:** As Erik, I want to press Cmd+1 through Cmd+9 to switch between channels by position, so that I can quickly jump to any channel without using the mouse.

#### Acceptance Criteria

1. WHEN Erik presses Cmd+1, THE Holoscape SHALL switch to the first channel in tab order.
2. WHEN Erik presses Cmd+N (where N is 2 through 9), THE Holoscape SHALL switch to the Nth channel in tab order.
3. THE tab order for keyboard shortcuts SHALL match the order displayed in the Sidebar (when expanded) or the Tab_Bar (when the Sidebar is collapsed).
4. IF fewer than N channels are open when Erik presses Cmd+N, THEN THE Holoscape SHALL take no action.
5. THE Cmd+1 through Cmd+9 shortcuts SHALL be active regardless of whether the Sidebar is expanded or collapsed.
6. THE Cmd+1 through Cmd+9 shortcuts SHALL be active regardless of which view or control currently has keyboard focus.

### Requirement 7: New Connection Types in Config

**User Story:** As Erik, I want the config file to support MCP and agent-chat connection types, so that I can define CEO and group chat sessions as profiles alongside my existing sessions.

#### Acceptance Criteria

1. THE ConnectionType enumeration SHALL include "mcp" and "agent-chat" in addition to the existing "local" and "ssh" types.
2. WHERE a Session_Profile has connection type "mcp", THE Session_Profile SHALL contain an endpoint field (string URL) specifying the MCP server address.
3. WHERE a Session_Profile has connection type "agent-chat", THE Session_Profile SHALL contain an api_url field (string URL) and an api_key_env field (string) specifying the environment variable name holding the API key.
4. THE Config_File serialization and deserialization SHALL maintain a round-trip property for Session_Profiles containing the new connection types: encoding a valid config to JSON and decoding the result SHALL produce an equivalent config.
5. IF the Config_File contains a Session_Profile with connection type "mcp" but missing the endpoint field, THEN THE Holoscape SHALL skip that profile and log a warning.
6. IF the Config_File contains a Session_Profile with connection type "agent-chat" but missing the api_url field, THEN THE Holoscape SHALL skip that profile and log a warning.

### Requirement 8: V2 Config File Extensions

**User Story:** As Erik, I want my theme selection, timestamp preference, and new channel states persisted in my config file, so that my V2 settings survive restarts.

#### Acceptance Criteria

1. THE AppearanceConfig SHALL include a themeName field (string) storing the active Color_Theme name.
2. THE AppearanceConfig SHALL include a themeOverrides field storing individual color overrides separately from the theme selection.
3. THE Config_File SHALL include a showTimestamps field (boolean) storing the timestamp display toggle state.
4. IF the Config_File exists but does not contain V2 fields (themeName, themeOverrides, showTimestamps), THEN THE Holoscape SHALL use default values ("Dark" theme, no overrides, timestamps disabled) without overwriting existing V1/V1.5 data.
5. THE Config_File serialization and deserialization SHALL maintain a round-trip property: encoding a valid config containing V2 fields to JSON and decoding the result SHALL produce an equivalent config.

### Requirement 9: MCP and Group Chat Channel State Persistence

**User Story:** As Erik, I want my CEO and group chat sessions to be restored when I relaunch Holoscape, so that I don't have to manually reopen these connections after every restart.

#### Acceptance Criteria

1. WHEN Holoscape exits normally, THE Holoscape SHALL save MCP_Channel metadata (Session_Profile label, connection type, endpoint) and Group_Chat_Channel metadata (Session_Profile label, connection type, api_url, api_key_env) to the Config_File alongside existing channel state.
2. WHEN Holoscape launches and finds saved MCP_Channel metadata, THE Holoscape SHALL recreate the MCP channel tab and attempt to re-establish the MCP_Client connection.
3. WHEN Holoscape launches and finds saved Group_Chat_Channel metadata, THE Holoscape SHALL recreate the group chat tab and begin polling the Agent_Chat_API.
4. IF a restored MCP_Channel fails to reconnect, THEN THE Holoscape SHALL display the channel tab in "disconnected" state with an option to retry or close.
5. IF a restored Group_Chat_Channel fails to connect to the Agent_Chat_API, THEN THE Holoscape SHALL display the channel tab in "disconnected" state with an option to retry or close.
