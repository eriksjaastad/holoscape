# Requirements Document

## Introduction

Holoscape Native Terminal is a ground-up native macOS terminal application built in Swift/AppKit that replaces iTerm/Warp with a channel-based interface. Channels are the core abstraction — named, typed connections to backends including local shell sessions, AI agent conversations (with auth isolation), and group chat connections. The application is built for a single user (Erik Sjaastad) who manages 4+ simultaneous AI agent sessions across two machines and needs unambiguous visual identity for each connection. V1 MVP covers shell channels, agent channels, group chat, bug reporting, crash detection, appearance settings, and channel state persistence.

## Glossary

- **Holoscape**: The native macOS terminal application being specified
- **Channel**: A named, typed connection to a backend (shell, agent, or group chat) displayed as a tab in the application
- **Shell_Channel**: A channel type that connects to a local zsh process via PTY
- **Agent_Channel**: A channel type that spawns a `claude` CLI process in a PTY with environment isolation; subtypes are Agent_Direct (OAuth auth) and Agent_API (API key auth)
- **Group_Chat_Channel**: A channel type that connects to the Agent Chat API via HTTP polling or WebSocket
- **Tab_Bar**: The horizontal bar across the top of the window displaying all open channels as clickable tabs
- **Channel_Role**: An identifier for the agent's function (e.g., Architect, Floor Manager, CEO), detected from CLAUDE.md or user-assigned
- **Channel_Context**: Additional identifying information such as project directory name or machine name
- **Instance_Number**: An auto-assigned numeric suffix when multiple channels share the same role (e.g., AR1, AR2)
- **Unread_Indicator**: A visual dot on a channel tab signaling new content arrived while the channel was not active
- **SwiftTerm**: The open-source terminal emulation library (github.com/migueldeicaza/SwiftTerm) used for PTY-based rendering
- **PTY**: Pseudo-terminal, the Unix mechanism for terminal I/O between Holoscape and child processes
- **Auth_Isolation**: The practice of ensuring each channel's spawned process has only its designated authentication credentials, preventing credential leakage between channels
- **SIL_API**: The Synth Insight Labs REST endpoint that receives bug reports and crash data
- **Agent_Chat_API**: The existing Flask application on Cloud Run that serves group chat messages
- **Config_File**: The JSON file at ~/.holoscape/config.json storing user appearance preferences and channel state
- **Crash_Report_Scanner**: The component that checks ~/Library/Logs/DiagnosticReports/ for Holoscape crash logs on launch
- **Input_Box**: The NSTextView-based text input area at the bottom of the window

## Requirements

### Requirement 1: Channel Lifecycle Management

**User Story:** As Erik, I want to create, close, and manage channels of different types, so that I can organize all my connections in one window.

#### Acceptance Criteria

1. WHEN Erik initiates channel creation, THE Holoscape SHALL present a channel type selector offering Shell_Channel, Agent_Direct, Agent_API, and Group_Chat_Channel options.
2. WHEN Erik selects a channel type and confirms, THE Holoscape SHALL create a new Channel, assign it an Instance_Number, add a tab to the Tab_Bar, and activate the new Channel.
3. WHEN Erik creates an Agent_Channel, THE Holoscape SHALL allow Erik to assign a Channel_Role label or detect the Channel_Role from the CLAUDE.md file in the working directory.
4. WHEN multiple channels share the same Channel_Role, THE Holoscape SHALL auto-assign sequential Instance_Numbers to distinguish the channels (e.g., AR1, AR2).
5. WHEN Erik closes a channel that has a running process, THE Holoscape SHALL display a confirmation dialog before terminating the process and removing the tab.
6. WHEN Erik closes a channel that has no running process, THE Holoscape SHALL remove the tab without a confirmation dialog.

### Requirement 2: Channel Switching and Tab Bar

**User Story:** As Erik, I want to switch between channels instantly via a tab bar with clear identity labels, so that I never confuse which agent or session I am interacting with.

#### Acceptance Criteria

1. THE Tab_Bar SHALL display each open Channel as a tab showing the Channel_Role label and Channel_Context.
2. WHEN Erik clicks a tab, THE Holoscape SHALL switch to that Channel with no perceptible rendering delay.
3. WHEN a Channel receives new content while Erik is viewing a different Channel, THE Tab_Bar SHALL display an Unread_Indicator dot on the Channel's tab.
4. WHEN a Channel has an Unread_Indicator, THE Tab_Bar SHALL reorder that Channel's tab to the leftmost position among unread tabs.
5. WHEN Erik views a Channel that has an Unread_Indicator, THE Tab_Bar SHALL remove the Unread_Indicator from that Channel's tab.
6. WHEN the number of open tabs exceeds the visible width of the Tab_Bar, THE Tab_Bar SHALL become horizontally scrollable.
7. WHEN Erik presses Cmd+W, THE Holoscape SHALL close the currently active Channel following the channel close behavior defined in Requirement 1.
8. THE Tab_Bar SHALL visually distinguish the active tab from inactive tabs.

### Requirement 3: Shell Channel — Local Terminal Emulation

**User Story:** As Erik, I want a fully functional local shell session in a channel, so that I can use Holoscape as my primary terminal.

#### Acceptance Criteria

1. WHEN a Shell_Channel is created, THE Holoscape SHALL spawn a local zsh process connected via PTY using SwiftTerm LocalProcessTerminalView.
2. THE Shell_Channel SHALL support full ANSI/VTE escape code rendering including cursor positioning, 256 colors, and alternate screen buffer.
3. THE Shell_Channel SHALL maintain a scrollback buffer with a configurable depth.
4. WHEN Erik types in the Input_Box and presses Enter, THE Shell_Channel SHALL send the input text to the zsh PTY as standard input.
5. WHEN the zsh process produces output, THE Shell_Channel SHALL render the output in the terminal view in real time.
6. THE Shell_Channel SHALL display "Shell" as its tab label in the Tab_Bar.

### Requirement 4: Agent Channel — Claude CLI Integration

**User Story:** As Erik, I want to spawn isolated Claude CLI sessions as channels with clear role labels, so that I can manage multiple agents without auth confusion.

#### Acceptance Criteria

1. WHEN an Agent_Direct channel is created, THE Holoscape SHALL spawn a `claude` CLI process in a PTY with the ANTHROPIC_API_KEY environment variable explicitly unset.
2. WHEN an Agent_API channel is created, THE Holoscape SHALL spawn a `claude` CLI process in a PTY with the ANTHROPIC_API_KEY environment variable injected from secure storage.
3. THE Agent_Channel SHALL spawn each `claude` process in a clean environment that contains only the designated authentication credentials for that channel type.
4. WHEN a CLAUDE.md file exists in the working directory of an Agent_Channel, THE Holoscape SHALL parse the CLAUDE.md file to detect the Channel_Role.
5. WHEN no CLAUDE.md file exists and no user-assigned label is provided, THE Holoscape SHALL display "Agent" as the default Channel_Role on the tab.
6. WHEN an Agent_Channel is a floor manager role, THE Tab_Bar SHALL display the project directory name as the Channel_Context (e.g., "FM-tracker").
7. THE Agent_Channel SHALL render all `claude` CLI output through SwiftTerm with full ANSI/VTE escape code support.

### Requirement 5: Group Chat Channel

**User Story:** As Erik, I want to connect to the agent chat API and see messages from all participants in a terminal-style format, so that I can follow group conversations alongside my other sessions.

#### Acceptance Criteria

1. WHEN a Group_Chat_Channel is created, THE Holoscape SHALL establish a connection to the Agent_Chat_API using HTTP polling or WebSocket with an X-API-Key header for authentication.
2. WHEN the Agent_Chat_API delivers a message, THE Group_Chat_Channel SHALL render the message in the format `[HH:MM PM] sender: message body` using monospace terminal-style rendering.
3. WHEN Erik types a message in the Input_Box and presses Enter, THE Group_Chat_Channel SHALL send the message to the Agent_Chat_API with "erik" as the sender identifier.
4. THE Group_Chat_Channel SHALL display messages from all participants including erik, claude-architect, mini-claude, and ceo.
5. THE Group_Chat_Channel SHALL maintain a scrollback buffer consistent with other channel types.
6. WHEN new messages arrive on a Group_Chat_Channel while Erik is viewing a different Channel, THE Tab_Bar SHALL display an Unread_Indicator on the Group_Chat_Channel tab.
7. IF the connection to the Agent_Chat_API fails, THEN THE Group_Chat_Channel SHALL display a connection error message in the terminal view and attempt to reconnect.

### Requirement 6: Text Input

**User Story:** As Erik, I want text input that works like a normal text editor with click-to-position, selection, and clipboard support, so that composing messages and commands feels natural.

#### Acceptance Criteria

1. THE Input_Box SHALL be implemented as an NSTextView positioned at the bottom of the window.
2. WHEN Erik clicks within the Input_Box, THE Input_Box SHALL position the cursor at the click location.
3. WHEN Erik uses Shift+Arrow keys or mouse drag, THE Input_Box SHALL select the corresponding text range.
4. WHEN Erik presses Delete or Backspace with a text selection active, THE Input_Box SHALL remove the selected text.
5. THE Input_Box SHALL support Cmd+A (select all), Cmd+C (copy), Cmd+V (paste), and Cmd+X (cut) keyboard shortcuts.
6. WHEN Erik presses Enter, THE Input_Box SHALL send the current text content to the active Channel and clear the Input_Box.
7. WHEN Erik presses Up Arrow in an empty Input_Box, THE Input_Box SHALL recall the previous command from the per-channel command history.
8. WHEN Erik presses Down Arrow while browsing command history, THE Input_Box SHALL navigate forward through the per-channel command history.

### Requirement 7: Bug Reporting

**User Story:** As Erik, I want to file bug reports with one keyboard shortcut that auto-attaches context, so that reporting issues to Mini Claude requires minimal effort.

#### Acceptance Criteria

1. WHEN Erik presses Cmd+B, THE Holoscape SHALL display a one-line input overlay for entering a bug description.
2. WHEN Erik types a description and presses Enter in the bug report overlay, THE Holoscape SHALL submit a bug report to the SIL_API via HTTP POST.
3. THE bug report payload SHALL include: the active Channel name, Channel type, the last 20 lines of terminal output from the active Channel, a timestamp, the macOS version, and Erik's description.
4. THE bug report payload SHALL NOT include API keys, full conversation content, or other sensitive credentials.
5. WHEN the SIL_API responds with a success status, THE Holoscape SHALL dismiss the overlay and display a brief confirmation.
6. IF the SIL_API responds with an error status, THEN THE Holoscape SHALL display the error to Erik in the overlay.

### Requirement 8: Crash Detection and Reporting

**User Story:** As Erik, I want Holoscape to detect its own crashes and offer one-click reporting on next launch, so that crash data reaches Mini Claude automatically.

#### Acceptance Criteria

1. WHEN Holoscape launches, THE Crash_Report_Scanner SHALL scan ~/Library/Logs/DiagnosticReports/ for Holoscape crash logs created since the last successful launch.
2. WHEN a crash log is found, THE Holoscape SHALL display a prompt: "Holoscape crashed. File a report?" with a one-click submit action.
3. WHEN Erik clicks submit on the crash report prompt, THE Holoscape SHALL POST the full crash trace and the last known channel state before the crash to the SIL_API.
4. THE Holoscape SHALL record the current launch timestamp so that subsequent launches only detect new crash logs.
5. THE crash report payload SHALL NOT include API keys or sensitive credentials.

### Requirement 9: Appearance Settings

**User Story:** As Erik, I want to customize background color, transparency, and font settings, so that Holoscape looks and feels the way I want.

#### Acceptance Criteria

1. THE Holoscape SHALL provide a settings interface for configuring background color, window transparency, font family, and font size.
2. WHEN Erik changes an appearance setting, THE Holoscape SHALL apply the change to the active window in real time.
3. THE Holoscape SHALL persist all appearance settings to the Config_File at ~/.holoscape/config.json.
4. WHEN Holoscape launches, THE Holoscape SHALL load appearance settings from the Config_File and apply them before displaying the window.
5. IF the Config_File does not exist or is malformed, THEN THE Holoscape SHALL use default appearance settings and create a valid Config_File.
6. THE Holoscape SHALL provide ANSI color palette customization for terminal rendering.

### Requirement 10: Channel State Persistence

**User Story:** As Erik, I want my open channels to be restored when I relaunch Holoscape, so that I don't have to manually recreate my workspace after every restart.

#### Acceptance Criteria

1. WHEN Holoscape exits normally, THE Holoscape SHALL save the list of open channels, their types, roles, contexts, and ordering to the Config_File.
2. WHEN Holoscape launches, THE Holoscape SHALL read the saved channel state from the Config_File and recreate the channels in the same order.
3. WHEN a Shell_Channel is restored, THE Holoscape SHALL spawn a new zsh process for the restored channel.
4. WHEN an Agent_Channel is restored, THE Holoscape SHALL spawn a new `claude` CLI process with the correct auth isolation for the restored channel type.
5. WHEN a Group_Chat_Channel is restored, THE Holoscape SHALL re-establish the connection to the Agent_Chat_API.
6. IF a restored channel fails to reconnect or spawn its process, THEN THE Holoscape SHALL display the channel tab in a "disconnected" state with an option to retry or close.

### Requirement 11: Window Layout

**User Story:** As Erik, I want a single-window layout with tab bar, terminal output, and input box, so that all my channels are accessible without managing multiple windows.

#### Acceptance Criteria

1. THE Holoscape SHALL operate as a single-window application.
2. THE Holoscape window SHALL display the Tab_Bar across the top, the terminal output area in the center at full width, and the Input_Box at the bottom.
3. THE terminal output area SHALL render content in monospace font.
4. THE Holoscape window SHALL support macOS native transparency.

### Requirement 12: Process Independence and Crash Resilience

**User Story:** As Erik, I want each channel's process to be independent so that an app crash does not kill my running agents.

#### Acceptance Criteria

1. THE Holoscape SHALL spawn each channel's backend process (zsh, claude CLI) as an independent child process with its own PID.
2. IF the Holoscape application process terminates unexpectedly, THEN the spawned channel processes SHALL continue running as independent operating system processes.
3. WHEN a channel's backend process terminates unexpectedly, THE Holoscape SHALL display a "disconnected" state on the channel tab and offer options to restart the process or close the channel.

### Requirement 13: Performance

**User Story:** As Erik, I want Holoscape to start fast and switch channels instantly, so that the tool never slows me down.

#### Acceptance Criteria

1. THE Holoscape SHALL display a usable window within 2 seconds of launch.
2. WHEN Erik switches channels, THE Holoscape SHALL render the target channel's content with no perceptible delay.
3. THE Shell_Channel terminal rendering performance SHALL match or exceed iTerm terminal rendering performance for equivalent workloads.

### Requirement 14: Privacy and Security

**User Story:** As Erik, I want zero telemetry and strict auth isolation, so that my data stays on my machine and credentials never leak between channels.

#### Acceptance Criteria

1. THE Holoscape SHALL NOT transmit any telemetry, analytics, or usage tracking data to any external service.
2. THE Holoscape SHALL ensure that OAuth-authenticated Agent_Direct channels have the ANTHROPIC_API_KEY environment variable explicitly unset in the spawned process environment.
3. THE Holoscape SHALL ensure that API-key-authenticated Agent_API channels have the ANTHROPIC_API_KEY injected only into the spawned process environment for that specific channel.
4. THE Holoscape SHALL NOT share environment variables between channel processes.
