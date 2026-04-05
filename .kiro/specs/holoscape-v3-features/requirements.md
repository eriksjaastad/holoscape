# Requirements Document: Holoscape V3 Features

## Introduction

Holoscape V3 is an incremental update to the shipped V1/V1.5/V2 native macOS terminal. V3 adds six capabilities on top of the existing channel-based architecture: desktop notifications for unread channels, window splitting for side-by-side channel viewing, a bridge channel for broadcasting to all agents, tab pinning, search across channel output, and a minimal Winamp-style skin engine (colors + images only, no layout changes). The application continues to target macOS Sequoia 15.0+ using Swift, AppKit, and SwiftTerm.

## Glossary

- **Holoscape**: The native macOS terminal application providing a channel-based interface for managing shell sessions, AI agent conversations, SSH connections, MCP connections, and group chat.
- **Channel**: A named, typed connection to a backend (shell, agent, SSH, MCP, group chat, or bridge) rendered in the sidebar/tab bar.
- **Notification_Service**: The component responsible for requesting notification permissions and delivering macOS desktop notifications via UNUserNotificationCenter.
- **Split_Manager**: The component responsible for managing recursive NSSplitView panes in the terminal area, tracking the active pane, and persisting split layout state.
- **Bridge_Channel**: A special channel type that broadcasts user input to all active agent channels simultaneously.
- **Pin_Manager**: The component responsible for tracking pinned tab state, enforcing pin ordering, and persisting pin metadata.
- **Search_Bar**: The UI component that appears at the top of the terminal area for searching the active channel's scrollback buffer.
- **Skin_Engine**: The component responsible for loading, parsing, and applying skin packages (colors + images) from `~/.holoscape/skins/`.
- **Active_Pane**: The split pane that currently receives keyboard input, visually indicated by a border highlight.
- **Agent_Channel**: Any channel whose backend is an AI agent process — includes agentDirect, agentAPI, SSH running claude, and MCP channel types.
- **Skin**: A directory containing a `skin.json` file and optional PNG image assets that define visual customization for Holoscape's UI.
- **PTY_Channel**: A channel backed by a pseudo-terminal (shell, agentDirect, agentAPI, SSH).
- **NSTextView_Channel**: A channel using a read-only NSTextView for rendering (MCP, group chat).

## Requirements

### Requirement 1: Desktop Notifications for Unread Channels

**User Story:** As Erik, I want to receive macOS desktop notifications when channels get new content while Holoscape is in the background, so that I can stay aware of agent activity without constantly checking the app.

#### Acceptance Criteria

1. WHEN Holoscape launches for the first time, THE Notification_Service SHALL request notification authorization from UNUserNotificationCenter.
2. IF notification authorization is denied, THEN THE Notification_Service SHALL continue operating without sending notifications and SHALL NOT prompt again until the user re-enables in System Settings.
3. WHEN a Channel receives new output AND Holoscape is not the frontmost application AND notifications are enabled for that channel's type, THE Notification_Service SHALL deliver a macOS notification containing the channel's display label as the title and the first line of new content truncated to 100 characters as the body.
4. WHEN the user clicks a delivered notification, THE Notification_Service SHALL bring Holoscape to the front and switch the active channel to the channel identified in the notification.
5. WHEN a Channel that already has a pending notification receives additional new output, THE Notification_Service SHALL update the existing notification for that channel instead of delivering a new notification.
6. WHILE Holoscape is the frontmost application, THE Notification_Service SHALL NOT deliver any notifications regardless of channel activity.
7. THE HoloscapeConfig SHALL include a `notifications` object containing an `enabled` boolean (default true) and a `perChannelType` dictionary mapping channel type strings ("shell", "agent", "ssh", "mcp", "groupChat") to boolean values.
8. WHEN the `notifications.enabled` flag is set to false, THE Notification_Service SHALL NOT deliver any notifications.
9. WHEN a specific channel type's entry in `perChannelType` is set to false, THE Notification_Service SHALL NOT deliver notifications for channels of that type.
10. THE AppearanceSettingsWindowController SHALL provide a "Notifications" section with a global enable/disable toggle and per-channel-type toggles for shell, agent, SSH, MCP, and group chat.

### Requirement 2: Window Splitting (Side-by-Side Channels)

**User Story:** As Erik, I want to view two or more channels side by side in the terminal area, so that I can monitor multiple agent conversations simultaneously without switching tabs.

#### Acceptance Criteria

1. WHEN the user presses Cmd+D, THE Split_Manager SHALL split the Active_Pane horizontally, creating a left pane (retaining the current channel) and a right pane (initially empty, showing a channel picker or the next channel in tab order).
2. WHEN the user presses Cmd+Shift+D, THE Split_Manager SHALL split the Active_Pane vertically, creating a top pane (retaining the current channel) and a bottom pane (initially empty, showing a channel picker or the next channel in tab order).
3. IF the total number of visible panes is already 4, THEN THE Split_Manager SHALL ignore further split requests.
4. WHEN the user clicks inside a split pane, THE Split_Manager SHALL set that pane as the Active_Pane, apply a subtle border highlight to the Active_Pane, and remove the highlight from all other panes.
5. WHILE a split pane is the Active_Pane, THE InputBoxView SHALL route all keyboard input to the channel displayed in the Active_Pane.
6. WHEN the user presses Cmd+Shift+W, THE Split_Manager SHALL close the Active_Pane and redistribute the space to the adjacent pane.
7. IF only one pane remains after closing a split pane, THEN THE Split_Manager SHALL return to the single-pane terminal layout.
8. THE Split_Manager SHALL persist the current split layout (number of panes, orientation, and channel assignments) in HoloscapeConfig so that the layout is restored on next launch.
9. THE Split_Manager SHALL track the Active_Pane ID independently from the sidebar's selected channel, allowing the sidebar selection and the Active_Pane to reference different channels.
10. WHEN a channel displayed in a split pane is closed via the sidebar, THE Split_Manager SHALL remove that pane and redistribute the space to the adjacent pane.

### Requirement 3: Bridge Channel (Broadcast to All Agents)

**User Story:** As Erik, I want a bridge channel that broadcasts my messages to all active agent channels at once, so that I can issue commands like "everyone stop" or "status report" without switching to each agent individually.

#### Acceptance Criteria

1. THE SessionProfileManager SHALL include a preconfigured "Bridge" session profile with connection type "bridge" that appears in the session launcher.
2. WHEN the user sends input in the Bridge_Channel, THE Bridge_Channel SHALL forward that input text to every active Agent_Channel (agentDirect, agentAPI, SSH running claude, and MCP channel types).
3. WHEN the Bridge_Channel broadcasts a message, THE Bridge_Channel SHALL NOT forward the message to shell channels.
4. WHEN the Bridge_Channel broadcasts a message, THE Bridge_Channel SHALL NOT forward the message to group chat channels.
5. WHEN the Bridge_Channel broadcasts a message, THE Bridge_Channel content view SHALL append a log entry formatted as `[H:MM PM] → broadcast: <message text>`.
6. WHEN an Agent_Channel receives a broadcast message, the response SHALL appear in that individual Agent_Channel's content view, not in the Bridge_Channel.
7. THE ChannelType enum SHALL include a `bridge` case.
8. THE ConnectionType enum SHALL include a `bridge` case.
9. THE ChannelManager SHALL create a BridgeChannelController when a session profile with connection type "bridge" is launched.
10. IF no Agent_Channels are currently active when the user sends input in the Bridge_Channel, THEN THE Bridge_Channel SHALL display a message "[System] No active agent channels to broadcast to."

### Requirement 4: Tab Pinning

**User Story:** As Erik, I want to pin important tabs so they stay in a fixed position at the top of the sidebar, so that unread reordering does not move my most-used channels away from where I expect them.

#### Acceptance Criteria

1. WHEN the user right-clicks a tab in the sidebar or tab bar, THE context menu SHALL include a "Pin" option for unpinned tabs and an "Unpin" option for pinned tabs.
2. WHEN the user selects "Pin" from the context menu, THE Pin_Manager SHALL mark that channel as pinned and move the tab to the pinned section at the top of the sidebar (or left of the tab bar).
3. WHEN the user selects "Unpin" from the context menu, THE Pin_Manager SHALL remove the pinned status from that channel and move the tab back to the unpinned section.
4. THE Pin_Manager SHALL order pinned tabs by the time they were pinned, with the earliest-pinned tab in the first position.
5. WHEN an unpinned channel transitions to unread, THE SidebarView SHALL reorder only unpinned tabs; pinned tabs SHALL remain in their fixed positions.
6. THE SidebarView SHALL display a small pin icon next to the label of each pinned tab.
7. THE ChannelMetadata SHALL include an optional `pinnedAt` timestamp field so that pin state and pin order persist across restarts.

### Requirement 5: Search Across Channel Output (Cmd+F)

**User Story:** As Erik, I want to search the scrollback buffer of the active channel, so that I can find specific output or messages without manually scrolling through long terminal history.

#### Acceptance Criteria

1. WHEN the user presses Cmd+F, THE Search_Bar SHALL appear at the top of the terminal area, below the tab bar, with a text input field focused for typing.
2. WHEN the user types in the Search_Bar, THE Search_Bar SHALL highlight all matching occurrences in the active channel's scrollback buffer.
3. WHEN the user presses Enter or Cmd+G while the Search_Bar is visible, THE Search_Bar SHALL jump to the next match in the scrollback buffer.
4. WHEN the user presses Cmd+Shift+G while the Search_Bar is visible, THE Search_Bar SHALL jump to the previous match in the scrollback buffer.
5. WHEN the user presses Escape while the Search_Bar is visible, THE Search_Bar SHALL close and remove all match highlights from the scrollback buffer.
6. THE Search_Bar SHALL search only the active channel's content — for PTY_Channels, the Search_Bar SHALL search the SwiftTerm terminal buffer text; for NSTextView_Channels, the Search_Bar SHALL search the NSTextView text storage.
7. WHEN the search query has no matches in the active channel's scrollback, THE Search_Bar SHALL display a "No matches" indicator.
8. WHEN the active channel changes while the Search_Bar is open, THE Search_Bar SHALL clear the current search results and re-execute the search query against the new active channel's content.
9. THE Search_Bar SHALL limit the searchable range to the most recent 10,000 lines of the active channel's scrollback buffer to maintain responsive search performance.

### Requirement 6: Winamp-Style Skin Engine (Minimal V3 Scope)

**User Story:** As Erik, I want to apply custom visual skins to Holoscape that change colors and background images, so that the terminal has a unique, personalized look inspired by classic Winamp skins.

#### Acceptance Criteria

1. THE Skin_Engine SHALL load skins from directories located at `~/.holoscape/skins/<skin-name>/`, where each directory contains a `skin.json` file and optional PNG image assets.
2. THE `skin.json` file SHALL define the following color properties: window background color, title bar background color, sidebar background color, tab active color, tab inactive color, text foreground color, and ANSI color palette (16 colors).
3. THE `skin.json` file SHALL define optional image asset references for: window background image, sidebar background image, and tab bar background image.
4. WHEN a skin is selected, THE Skin_Engine SHALL apply the skin's color definitions to all relevant UI elements and display referenced image assets as backgrounds.
5. THE AppearanceSettingsWindowController SHALL provide a skin picker dropdown listing all available skins found in `~/.holoscape/skins/` plus the built-in "Default" skin.
6. WHEN no custom skin is selected, THE Skin_Engine SHALL use the built-in Dark theme as the default skin.
7. THE HoloscapeConfig appearance section SHALL include an optional `skinName` field that persists the selected skin across restarts.
8. IF a skin directory referenced by `skinName` is missing or contains an invalid `skin.json`, THEN THE Skin_Engine SHALL fall back to the built-in Dark theme and log a warning.
9. THE Skin_Engine in V3 SHALL support color and image customization only — layout changes (element positioning, sizing, custom window chrome) SHALL be deferred to V4.
10. WHEN a user shares a skin as a zip file, THE Skin_Engine SHALL support loading a skin by extracting the zip contents into `~/.holoscape/skins/<skin-name>/`.
