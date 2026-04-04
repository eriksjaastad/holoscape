# Requirements Document — Holoscape V1.5: Session Launcher and Sidebar

## Introduction

Holoscape V1.5 is an incremental update to the existing Holoscape Native Terminal (V1). V1 provides local shell channels, agent channels (Claude CLI with auth isolation), group chat, bug reporting, crash detection, appearance settings, and channel state persistence. V1.5 adds four major capabilities: a profile-driven session launcher that replaces the Cmd+N modal picker, SSH agent channels for running Claude on a remote MacBook, a collapsible left sidebar for tab management, and right-click context menus on tabs. Group Chat and CEO Connection are explicitly out of scope for V1.5 (deferred to V2).

This document specifies only the NEW requirements introduced in V1.5. All V1 requirements remain in effect and are not repeated here.

## Glossary

- **Holoscape**: The native macOS terminal application being specified
- **Session_Profile**: A configuration record defining everything needed to open a connection: label, connection type, host, user, directory, and command
- **Session_Launcher**: The combobox-style dropdown UI for browsing and launching sessions from profiles
- **SSH_Agent_Channel**: A channel type that connects to a remote machine via SSH and runs a command (e.g., `claude`) in a PTY over the SSH connection
- **Sidebar**: A collapsible left panel displaying open channels as a vertical tab list, replacing the horizontal Tab_Bar when expanded
- **Tab_Bar**: The horizontal bar across the top of the window displaying open channels (V1 behavior, used when Sidebar is collapsed)
- **Context_Menu**: A right-click menu on any tab (sidebar or top bar) offering actions: Close, Rename, Duplicate, Reconnect, Copy Session Info
- **Project_Discovery**: The process of scanning a remote directory over SSH to find project subdirectories and generate launchable session entries
- **Config_File**: The JSON file at ~/.holoscape/config.json storing session profiles, appearance, sidebar state, and channel state
- **SSH_Defaults**: Default SSH connection parameters (host, user) applied to SSH sessions that do not specify their own
- **Instance_Number**: An auto-assigned numeric suffix when multiple sessions share the same label (e.g., mini-claude 1, mini-claude 2)
- **SwiftTerm**: The open-source terminal emulation library used for PTY-based rendering (local and SSH)
- **PTY**: Pseudo-terminal, the Unix mechanism for terminal I/O
- **Channel_Manager**: The central registry that creates, tracks, closes, persists, and restores channels

## Requirements

### Requirement 1: Session Profile Configuration

**User Story:** As Erik, I want to define reusable session profiles in my config file, so that I can launch any connection type with one click instead of manually configuring each session.

#### Acceptance Criteria

1. THE Config_File SHALL support a `session_profiles` array where each entry is a Session_Profile containing: label (string), connection type ("local" or "ssh"), command (string), and directory (string).
2. WHERE a Session_Profile has connection type "ssh", THE Session_Profile SHALL additionally contain host (string) and user (string) fields.
3. THE Config_File SHALL support an `ssh_defaults` object containing host and user fields that apply to SSH sessions that omit their own host or user.
4. WHEN a Session_Profile with connection type "ssh" omits the host or user field, THE Holoscape SHALL use the corresponding value from `ssh_defaults`.
5. IF the Config_File contains a Session_Profile with missing required fields (label, connection, command, directory), THEN THE Holoscape SHALL skip that profile and log a warning.
6. THE Config_File SHALL support a `project_discovery` object containing: enabled (boolean), root (string path), connection type (string), and command (string).

### Requirement 2: Session Launcher UI

**User Story:** As Erik, I want a combobox launcher at the top of the sidebar that shows all available sessions, so that I can open any session in one click without navigating menus.

#### Acceptance Criteria

1. THE Sidebar SHALL display a session launch button at the top of the panel.
2. WHEN Erik clicks the session launch button, THE Session_Launcher SHALL display a dropdown combobox listing all available sessions grouped by: preconfigured Session_Profiles, auto-discovered project sessions, and recently used sessions sorted by recency.
3. WHEN Erik selects an item from the Session_Launcher dropdown, THE Holoscape SHALL immediately open a new session using that Session_Profile, create a tab, and activate the new channel.
4. THE Session_Launcher combobox SHALL be editable, allowing Erik to type text to filter the session list.
5. WHEN Erik types a name in the Session_Launcher that does not match any existing session, THE Holoscape SHALL treat the typed name as a new project directory name and open a floor manager Claude session in `~/projects/<typed-name>/` on the remote MacBook using SSH_Defaults.
6. WHEN a session is launched, THE Holoscape SHALL record the session label and timestamp in a recently used list persisted to the Config_File.
7. THE Session_Launcher SHALL display recently used sessions sorted by most recent first.

### Requirement 3: Project Discovery via SSH

**User Story:** As Erik, I want Holoscape to automatically discover project directories on my MacBook, so that each project appears as a launchable floor manager session without manual configuration.

#### Acceptance Criteria

1. WHEN project_discovery is enabled in the Config_File, THE Holoscape SHALL connect to the configured SSH host and list the immediate subdirectories of the configured root path.
2. THE Holoscape SHALL execute the directory listing over SSH using the system SSH agent for authentication.
3. WHEN the directory listing completes, THE Holoscape SHALL create a virtual Session_Profile for each discovered subdirectory with: the subdirectory name as the label, the configured connection type, the configured command, and the full subdirectory path as the directory.
4. THE Holoscape SHALL cache the discovered project list locally to avoid repeated SSH connections on every Session_Launcher open.
5. THE Session_Launcher SHALL provide a manual refresh action to re-scan the remote project directories.
6. IF the SSH connection for project discovery fails, THEN THE Holoscape SHALL display the cached project list (if available) and show a non-blocking error indicating the discovery refresh failed.
7. IF no cached project list exists and the SSH connection fails, THEN THE Holoscape SHALL display only the preconfigured Session_Profiles and recently used sessions in the Session_Launcher.

### Requirement 4: SSH Agent Channel

**User Story:** As Erik, I want to open SSH sessions to my MacBook and run Claude in remote project directories, so that I can manage agents on both machines from one window.

#### Acceptance Criteria

1. WHEN a session with connection type "ssh" is launched, THE Holoscape SHALL establish an SSH connection to the specified host and user using the system SSH agent for key authentication.
2. THE SSH_Agent_Channel SHALL allocate a PTY on the remote machine and execute the configured command in the configured directory.
3. THE SSH_Agent_Channel SHALL render all remote terminal output through SwiftTerm with full ANSI/VTE escape code support.
4. WHEN Erik types in the Input_Box and presses Enter while an SSH_Agent_Channel is active, THE SSH_Agent_Channel SHALL send the input text to the remote PTY as standard input.
5. THE SSH_Agent_Channel tab label SHALL display the Session_Profile label followed by the Instance_Number.
6. WHEN an SSH_Agent_Channel is a project session (launched from project discovery or typed name), THE SSH_Agent_Channel tab label SHALL display the project directory name as the label.
7. IF the SSH connection fails during channel creation, THEN THE Holoscape SHALL display the channel tab in a "disconnected" state with the failure reason and offer a retry option.
8. IF an established SSH connection drops unexpectedly, THEN THE Holoscape SHALL transition the channel to "disconnected" state and preserve the last terminal output.
9. THE Holoscape SHALL NOT manage SSH keys or credentials — authentication relies entirely on the system SSH agent.

### Requirement 5: Consistent Instance Numbering

**User Story:** As Erik, I want all sessions with the same label to be numbered consistently, so that I can distinguish between multiple instances of the same session type.

#### Acceptance Criteria

1. WHEN multiple channels share the same Session_Profile label, THE Holoscape SHALL assign sequential Instance_Numbers starting from 1 to each channel (e.g., mini-claude 1, mini-claude 2).
2. THE Instance_Number SHALL apply to all connection types equally (local and SSH sessions both receive numbering).
3. WHEN only one channel exists with a given label, THE Holoscape SHALL display the label without an Instance_Number suffix.
4. WHEN a numbered channel is closed, THE Holoscape SHALL NOT renumber the remaining channels with the same label.
5. WHEN a new channel is created with a label that has existing instances, THE Holoscape SHALL assign the next sequential Instance_Number that has not been used in the current application session.

### Requirement 6: Session Label from Profile

**User Story:** As Erik, I want tab labels to come from my session profile configuration rather than runtime detection, so that labels are predictable and consistent.

#### Acceptance Criteria

1. WHEN a session is launched from a Session_Profile, THE Holoscape SHALL use the Session_Profile label as the channel's display label.
2. WHEN a session is launched from project discovery, THE Holoscape SHALL use the project directory name as the channel's display label.
3. WHEN a session is launched by typing a new name in the Session_Launcher, THE Holoscape SHALL use the typed name as the channel's display label.
4. THE Holoscape SHALL NOT parse CLAUDE.md at runtime to determine channel labels for sessions launched via the Session_Launcher.

### Requirement 7: Collapsible Sidebar

**User Story:** As Erik, I want a collapsible left sidebar showing my open tabs vertically, so that I can see more tab detail when I have many sessions open and collapse it when I need more terminal space.

#### Acceptance Criteria

1. THE Holoscape SHALL display a left sidebar panel containing a vertical list of all open channel tabs.
2. EACH sidebar tab entry SHALL display: the channel label (with Instance_Number if applicable), an unread indicator dot, and the connection status.
3. WHEN Erik clicks a tab in the Sidebar, THE Holoscape SHALL switch to that channel.
4. THE Sidebar SHALL provide a toggle control (button or drag handle) to collapse and expand the panel.
5. WHEN the Sidebar is collapsed, THE Holoscape SHALL display the horizontal Tab_Bar across the top of the window (V1 behavior).
6. WHEN the Sidebar is expanded, THE Holoscape SHALL hide the horizontal Tab_Bar.
7. THE Holoscape SHALL persist the Sidebar state (expanded or collapsed) to the Config_File and restore the state on launch.
8. WHEN a channel has unread content while the Sidebar is expanded, THE Sidebar SHALL move that channel's tab entry to the top of the list.
9. THE Sidebar SHALL be scrollable when the number of open tabs exceeds the visible height.

### Requirement 8: Right-Click Context Menu on Tabs

**User Story:** As Erik, I want to right-click any tab to access common actions, so that I can manage sessions without memorizing keyboard shortcuts.

#### Acceptance Criteria

1. WHEN Erik right-clicks a tab in the Sidebar or the Tab_Bar, THE Holoscape SHALL display a context menu with the following items: Close, Rename, Duplicate, Reconnect, and Copy Session Info.
2. WHEN Erik selects "Close" from the Context_Menu, THE Holoscape SHALL close the channel following the existing close confirmation behavior for channels with running processes.
3. WHEN Erik selects "Rename" from the Context_Menu, THE Holoscape SHALL present an inline text field allowing Erik to change the tab's display label.
4. WHEN Erik confirms a new label via the Rename action, THE Holoscape SHALL update the tab's display label in both the Sidebar and the Tab_Bar.
5. WHEN Erik selects "Duplicate" from the Context_Menu, THE Holoscape SHALL open a new session using the same Session_Profile as the selected tab's channel.
6. WHEN Erik selects "Reconnect" from the Context_Menu on a channel in "disconnected" state, THE Holoscape SHALL attempt to restart the channel's backend process or SSH connection.
7. WHEN Erik selects "Reconnect" from the Context_Menu on a channel in "active" state, THE Context_Menu SHALL display the Reconnect item in a disabled (grayed out) state.
8. WHEN Erik selects "Copy Session Info" from the Context_Menu, THE Holoscape SHALL copy the channel's connection details (label, connection type, host, directory, command) to the system clipboard as plain text.

### Requirement 9: Config File Extension for V1.5

**User Story:** As Erik, I want my session profiles, sidebar state, and recently used sessions persisted in my config file, so that my setup survives restarts.

#### Acceptance Criteria

1. THE Config_File SHALL store session_profiles, ssh_defaults, project_discovery settings, sidebar state (expanded or collapsed), and recently used session entries alongside the existing appearance and channel state data.
2. WHEN Holoscape saves the Config_File, THE Holoscape SHALL preserve all existing V1 config fields (appearance, channels, lastLaunchTimestamp) alongside the new V1.5 fields.
3. IF the Config_File exists but does not contain V1.5 fields (session_profiles, ssh_defaults, project_discovery, sidebar state), THEN THE Holoscape SHALL use default values for the missing V1.5 fields without overwriting existing V1 data.
4. THE Config_File serialization and deserialization SHALL maintain a round-trip property: encoding a valid config to JSON and decoding the result SHALL produce an equivalent config.

### Requirement 10: SSH Channel State Persistence

**User Story:** As Erik, I want my SSH sessions to be restored when I relaunch Holoscape, so that I don't have to manually reopen remote connections after every restart.

#### Acceptance Criteria

1. WHEN Holoscape exits normally, THE Holoscape SHALL save SSH_Agent_Channel metadata (Session_Profile label, connection type, host, user, directory, command) to the Config_File alongside existing channel state.
2. WHEN Holoscape launches and finds saved SSH_Agent_Channel metadata, THE Holoscape SHALL recreate the SSH channel tabs and attempt to re-establish the SSH connections.
3. IF a restored SSH_Agent_Channel fails to reconnect, THEN THE Holoscape SHALL display the channel tab in a "disconnected" state with an option to retry or close.
