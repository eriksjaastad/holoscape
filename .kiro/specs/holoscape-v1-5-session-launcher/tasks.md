# Implementation Plan: Holoscape V1.5 — Session Launcher and Sidebar

## Overview

Incremental update to the existing Holoscape V1 app. Tasks modify and extend existing Swift/AppKit code — no rebuild. The implementation proceeds bottom-up: new models first, then services, then controllers, then views, then wiring into MainWindowController. Each task builds on the previous and ends with integration.

## Tasks

- [ ] 1. Add V1.5 data models and extend existing models
  - [ ] 1.1 Create SessionProfile, SSHDefaults, ProjectDiscoveryConfig, and RecentSession models
    - Create `Sources/Holoscape/Models/SessionProfile.swift` with `SessionProfile` struct (Codable, Equatable, Sendable) containing label, connection (ConnectionType enum: local/ssh), command, directory, host?, user?
    - Create `Sources/Holoscape/Models/SSHDefaults.swift` with `SSHDefaults` struct and `.default` static
    - Create `Sources/Holoscape/Models/ProjectDiscoveryConfig.swift` with `ProjectDiscoveryConfig` struct and `.default` static
    - Create `Sources/Holoscape/Models/RecentSession.swift` with `RecentSession` struct (label, timestamp)
    - Add `resolved(with: SSHDefaults?)` method on SessionProfile that fills in missing host/user from defaults for SSH connections
    - _Requirements: 1.1, 1.2, 1.3, 1.6_

  - [ ] 1.2 Extend HoloscapeConfig with V1.5 optional fields
    - Add optional fields to `HoloscapeConfig` in `Sources/Holoscape/Models/HoloscapeConfig.swift`: sessionProfiles, sshDefaults, projectDiscovery, sidebarExpanded, recentSessions
    - All new fields must be `Optional` so V1 config files decode without error
    - Update `HoloscapeConfig.default` to include nil for all V1.5 fields
    - _Requirements: 9.1, 9.2, 9.3_

  - [ ] 1.3 Extend ChannelType with .ssh case and ChannelMetadata with SSH fields
    - Add `.ssh` case to `ChannelType` enum in `Sources/Holoscape/Models/ChannelType.swift`
    - Add optional host, user, command fields to `ChannelMetadata` in `Sources/Holoscape/Models/ChannelMetadata.swift`
    - _Requirements: 4.1, 10.1_

  - [ ]* 1.4 Write property tests for V1.5 config round-trip and backward compatibility
    - **Property 1: V1.5 Config serialization round-trip** — generate random HoloscapeConfig with V1+V1.5 fields, verify decode(encode(config)) == config
    - **Validates: Requirements 1.1, 1.3, 1.6, 9.1, 9.2, 9.4**
    - **Property 2: V1 config backward compatibility** — generate V1-only configs, encode, decode as V1.5, verify V1 fields preserved and V1.5 fields nil
    - **Validates: Requirements 9.3**
    - Create `Tests/HoloscapePropertyTests/ConfigV15RoundTripPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ConfigBackwardCompatPropertyTests.swift`

  - [ ]* 1.5 Write property test for SSH defaults resolution
    - **Property 3: SSH defaults resolution** — generate random SSH SessionProfiles with nil/empty host/user and random SSHDefaults, verify resolved(with:) fills in defaults correctly while preserving other fields
    - **Validates: Requirements 1.4, 2.5**
    - Create `Tests/HoloscapePropertyTests/SSHDefaultsResolutionPropertyTests.swift`

  - [ ]* 1.6 Write unit tests for new models
    - Create `Tests/HoloscapeTests/Unit/SessionProfileTests.swift`
    - Test specific SessionProfile JSON encoding/decoding (local, SSH with host, SSH without host)
    - Test resolved(with:) with specific defaults
    - Test invalid profile detection (missing required fields)
    - Test HoloscapeConfig loading V1-only JSON, verify V1.5 fields are nil
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 9.3_

- [ ] 2. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 3. Implement SSHChannelController
  - [ ] 3.1 Create SSHChannelController
    - Create `Sources/Holoscape/Controllers/SSHChannelController.swift`
    - Implement ChannelController protocol and LocalProcessTerminalViewDelegate
    - Use LocalProcessTerminalView + PTY pattern (same as ShellChannelController) but spawn `/usr/bin/ssh` with args `["-t", "user@host", "cd <dir> && <command>"]`
    - Filter environment to pass SSH_AUTH_SOCK, PATH, HOME, SHELL, TERM, LANG
    - Handle processTerminated to transition to .disconnected state
    - Implement displayLabel from profile.label + instanceNumber
    - Implement retry() to re-activate the SSH connection
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.7, 4.8, 4.9_

  - [ ]* 3.2 Write property tests for SSH command construction and display label
    - **Property 6: SSH command argument construction** — generate random SSH profiles, verify args are ["-t", "user@host", "cd dir && command"]
    - **Validates: Requirements 4.2**
    - **Property 7: Channel display label matches profile label** — generate random labels and optional instance numbers, verify displayLabel format
    - **Validates: Requirements 4.5, 6.1, 6.2, 6.3**
    - Create `Tests/HoloscapePropertyTests/SSHCommandPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/DisplayLabelPropertyTests.swift`

  - [ ]* 3.3 Write unit tests for SSHChannelController
    - Create `Tests/HoloscapeTests/Unit/SSHChannelControllerTests.swift`
    - Test displayLabel with specific label/instance combinations
    - Test activate() constructs correct ssh arguments for a known profile
    - Test environment filtering includes SSH_AUTH_SOCK
    - _Requirements: 4.2, 4.5, 4.9_

- [ ] 4. Implement ProjectDiscoveryService
  - [ ] 4.1 Create ProjectDiscoveryService
    - Create `Sources/Holoscape/Services/ProjectDiscoveryService.swift`
    - Implement discover() that runs `ssh user@host "ls -1 <root>"` as a one-shot Process
    - Parse output into directory names, generate SessionProfile for each with label=dirName, connection=.ssh, command from discovery config, directory=root/dirName
    - Implement in-memory caching: return cached results on SSH failure
    - Implement refresh() that clears cache and re-discovers
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7_

  - [ ]* 4.2 Write property tests for discovery profile generation and caching
    - **Property 4: Discovery produces correct SessionProfiles** — generate random directory name lists and ProjectDiscoveryConfig, verify generated profiles have correct fields
    - **Validates: Requirements 3.3**
    - **Property 5: Discovery caching returns consistent results on failure** — generate random cached profile lists, simulate failure, verify cached results returned unchanged
    - **Validates: Requirements 3.4, 3.6**
    - Create `Tests/HoloscapePropertyTests/DiscoveryProfilePropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/DiscoveryCachingPropertyTests.swift`

  - [ ]* 4.3 Write unit tests for ProjectDiscoveryService
    - Create `Tests/HoloscapeTests/Unit/ProjectDiscoveryTests.swift`
    - Test with mocked Process output: empty, single directory, multiple directories
    - Test cache behavior on simulated failure
    - _Requirements: 3.3, 3.4, 3.6, 3.7_

- [ ] 5. Implement SessionProfileManager
  - [ ] 5.1 Create SessionProfileManager
    - Create `Sources/Holoscape/Services/SessionProfileManager.swift`
    - Implement allSessions() returning (preconfigured, discovered, recent) tuple
    - Implement recordRecentSession(label:) that deduplicates, prepends, caps at 20, and persists to config
    - Implement resolve(label:) that checks preconfigured → discovered → creates new SSH project session using ssh_defaults
    - _Requirements: 2.2, 2.5, 2.6, 2.7_

  - [ ]* 5.2 Write property tests for recent session recording and launcher grouping
    - **Property 11: Recent session recording preserves order** — generate random sequences of label recordings, verify recent list ordering and uniqueness
    - **Validates: Requirements 2.6**
    - **Property 9: Launcher items are correctly grouped and sorted** — generate random preconfigured/discovered/recent sets, verify grouping order and recent sorting
    - **Validates: Requirements 2.2, 2.7**
    - Create `Tests/HoloscapePropertyTests/RecentSessionPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/LauncherGroupingPropertyTests.swift`

  - [ ]* 5.3 Write unit tests for SessionProfileManager
    - Create `Tests/HoloscapeTests/Unit/SessionProfileManagerTests.swift`
    - Test resolve() with known preconfigured profile, known discovered project, and unknown label
    - Test recordRecentSession with specific labels and verify ordering
    - _Requirements: 2.2, 2.5, 2.6_

- [ ] 6. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Update ChannelManager for V1.5 session creation and instance numbering
  - [ ] 7.1 Add createChannel(from: SessionProfile) to ChannelManager
    - Add new method to `Sources/Holoscape/Controllers/ChannelManager.swift`
    - Dispatch to ShellChannelController (local + zsh), AgentChannelController (local + claude), or SSHChannelController (ssh) based on profile
    - Store sshDefaults reference for profile resolution
    - _Requirements: 2.3, 4.1_

  - [ ] 7.2 Update instance numbering to high-water-mark strategy
    - Replace current `instanceCounters` logic with `highWaterMarks: [String: Int]` dictionary
    - First channel with a label gets no number; second triggers retroactive numbering of the first (assign 1) and new gets 2
    - Closing a channel never renumbers remaining channels
    - Next creation always gets highWaterMark + 1
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

  - [ ] 7.3 Update saveState/restoreState for SSH channel metadata
    - Extend saveState() to include host, user, command fields in ChannelMetadata for SSH channels
    - Extend restoreState() factory to handle .ssh type by reconstructing SSHChannelController from saved metadata
    - _Requirements: 10.1, 10.2, 10.3_

  - [ ]* 7.4 Write property test for instance numbering
    - **Property 8: Stable instance numbering across creates and closes** — generate random sequences of create/close operations with shared labels, verify: sequential assignment, no renumbering on close, high-water-mark never reuses numbers, single channel has no suffix
    - **Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5**
    - Create `Tests/HoloscapePropertyTests/InstanceNumberingPropertyTests.swift`

  - [ ]* 7.5 Write unit tests for ChannelManager V1.5 changes
    - Create `Tests/HoloscapeTests/Unit/InstanceNumberingTests.swift`
    - Test specific sequences: create 2 with same label, close first, create third — verify numbers are 1, 2, 3
    - Test createChannel(from:) dispatches to correct controller type
    - Test SSH metadata save/restore round-trip
    - _Requirements: 5.1, 5.4, 5.5, 10.1, 10.2_

- [ ] 8. Implement SidebarView
  - [ ] 8.1 Create SidebarView with vertical tab list
    - Create `Sources/Holoscape/Views/SidebarView.swift`
    - Implement NSView subclass with NSScrollView containing NSStackView of tab entries
    - Each tab entry shows: label (with instance number), unread dot, connection status indicator
    - Active tab visually distinct from inactive
    - Support click to select via SidebarViewDelegate
    - Move unread channels to top of list
    - _Requirements: 7.1, 7.2, 7.3, 7.8, 7.9_

  - [ ] 8.2 Create SessionLauncherView with NSComboBox
    - Create `Sources/Holoscape/Views/SessionLauncherView.swift`
    - Implement NSComboBox with NSComboBoxDataSource and NSComboBoxDelegate
    - Group items: preconfigured, discovered, recent (with section headers as disabled items)
    - Support type-to-filter behavior
    - Add refresh button for project discovery
    - Fire delegate on selection or Enter on non-matching text
    - _Requirements: 2.1, 2.2, 2.4, 2.7, 3.5_

  - [ ]* 8.3 Write property test for combobox filtering
    - **Property 10: Combobox filter matches by label substring** — generate random item lists and filter strings, verify filtered results contain exactly items whose label contains the filter string (case-insensitive)
    - **Validates: Requirements 2.4**
    - Create `Tests/HoloscapePropertyTests/ComboboxFilterPropertyTests.swift`

- [ ] 9. Integrate sidebar and launcher into MainWindowController
  - [ ] 9.1 Refactor MainWindowController layout to NSSplitView
    - Replace current flat layout in `Sources/Holoscape/Controllers/MainWindowController.swift` with NSSplitView (vertical split)
    - Left pane: sidebar container (SessionLauncherView at top, SidebarView below)
    - Right pane: TabBarView (hidden when sidebar expanded) + TerminalContainerView + InputBoxView
    - Set holding priorities so sidebar can collapse while terminal keeps space
    - _Requirements: 7.1, 7.5, 7.6_

  - [ ] 9.2 Implement sidebar toggle and state persistence
    - Add toggleSidebar() method: expand sets sidebar width to 220, collapse sets to 0
    - Toggle TabBarView visibility inversely with sidebar state
    - Persist sidebarExpanded to config via ConfigService on toggle
    - Restore sidebar state from config on launch
    - _Requirements: 7.4, 7.5, 7.6, 7.7_

  - [ ]* 9.3 Write property test for sidebar/TabBar mutual exclusivity
    - **Property 12: Sidebar and TabBar mutual exclusivity** — generate random sidebar toggle sequences, verify TabBarView hidden iff sidebar expanded
    - **Validates: Requirements 7.5, 7.6**
    - Create `Tests/HoloscapePropertyTests/SidebarVisibilityPropertyTests.swift`

  - [ ] 9.4 Wire SessionLauncherView to SessionProfileManager and ChannelManager
    - Implement SessionLauncherDelegate in MainWindowController
    - On selection: resolve label via SessionProfileManager, create channel via ChannelManager.createChannel(from:), record recent session, activate and switch to new channel
    - On typed new name: resolve creates SSH project session, launch it
    - On refresh: call ProjectDiscoveryService.refresh(), reload launcher items
    - _Requirements: 2.3, 2.5, 2.6_

  - [ ] 9.5 Wire SidebarView to ChannelManager
    - Implement SidebarViewDelegate in MainWindowController
    - On tab click: switchToChannel
    - Update sidebar on channel create/close/unread changes (call sidebarView.updateTabs)
    - Sync sidebar and TabBarView — both reflect same channel state
    - _Requirements: 7.1, 7.3, 7.8_

- [ ] 10. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 11. Implement right-click context menu on tabs
  - [ ] 11.1 Build context menu and action handlers in MainWindowController
    - Add buildContextMenu(for:) method to MainWindowController returning NSMenu with: Close, Rename, Duplicate, Reconnect (disabled if active), Copy Session Info
    - Implement Close action: reuse existing closeChannel logic with confirmation
    - Implement Rename action: show inline NSTextField, update displayLabel on confirm, reject empty strings
    - Implement Duplicate action: resolve original channel's SessionProfile, create new channel from it
    - Implement Reconnect action: call retry() on disconnected channel
    - Implement Copy Session Info: format label, connection type, host, directory, command as plain text, copy to NSPasteboard
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8_

  - [ ] 11.2 Attach context menu to SidebarView and TabBarView
    - Add right-click (NSView.menu(for:)) handling to SidebarView tab entries
    - Add right-click handling to TabBarView tab buttons
    - Both delegate to MainWindowController.buildContextMenu(for:)
    - _Requirements: 8.1_

  - [ ]* 11.3 Write property tests for context menu state
    - **Property 13: Context menu Reconnect enabled state** — generate channels with random states, verify Reconnect enabled iff disconnected
    - **Validates: Requirements 8.7**
    - **Property 14: Copy Session Info contains all connection details** — generate random channel metadata, verify output string contains all fields
    - **Validates: Requirements 8.8**
    - Create `Tests/HoloscapePropertyTests/ContextMenuPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/CopySessionInfoPropertyTests.swift`

  - [ ]* 11.4 Write unit tests for context menu
    - Create `Tests/HoloscapeTests/Unit/ContextMenuTests.swift`
    - Test menu items for active channel (Reconnect disabled), disconnected channel (Reconnect enabled)
    - Test Copy Session Info output format
    - _Requirements: 8.7, 8.8_

- [ ] 12. Wire SSH channel persistence and restoration
  - [ ] 12.1 Update AppDelegate to persist and restore SSH channels on launch/exit
    - On app exit: call channelManager.saveState() which now includes SSH metadata
    - On app launch: call channelManager.restoreState() with factory that handles .ssh type, attempt SSH reconnection
    - Display restored SSH channels in disconnected state if reconnection fails, with retry option
    - _Requirements: 10.1, 10.2, 10.3_

  - [ ]* 12.2 Write property test for SSH metadata persistence round-trip
    - **Property 15: SSH channel metadata persistence round-trip** — generate random SSH ChannelMetadata lists, verify save/load produces same list with identical field values
    - **Validates: Requirements 10.1, 10.2**
    - Create `Tests/HoloscapePropertyTests/SSHMetadataRoundTripPropertyTests.swift`

- [ ] 13. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- All tasks modify/extend the existing V1 codebase — no files are rebuilt from scratch
