# Implementation Plan: Holoscape Native Terminal

## Overview

Incremental build of the Holoscape native macOS terminal app in Swift/AppKit. Each task builds on the previous, starting with project scaffolding and core data models, then layering in services, channel controllers, views, and finally integration wiring. SwiftTerm is used for PTY-based channels; custom NSTextView for group chat. XCTest + SwiftCheck for testing.

## Tasks

- [ ] 1. Set up Xcode project structure and dependencies
  - [ ] 1.1 Create macOS App target (Holoscape) with Swift Package Manager
    - Add SwiftTerm dependency (github.com/migueldeicaza/SwiftTerm)
    - Add SwiftCheck dependency (github.com/typelift/SwiftCheck) for test target
    - Configure deployment target: macOS 15.0 (Sequoia)
    - Create test targets: HoloscapeTests (unit) and HoloscapePropertyTests (property)
    - _Requirements: 11.1_

  - [ ] 1.2 Define core data models and enums
    - Create `Models/ChannelType.swift` with `ChannelType` enum (shell, agentDirect, agentAPI, groupChat)
    - Create `Models/AgentAuthType.swift` with `AgentAuthType` enum (oauth, apiKey)
    - Create `Models/ChannelState.swift` with `ChannelState` enum (active, disconnected, connecting)
    - Create `Models/ChannelMetadata.swift` with `ChannelMetadata` struct (id, type, role, context, instanceNumber, workingDirectory)
    - Create `Models/HoloscapeConfig.swift` with `HoloscapeConfig` and `AppearanceConfig` structs
    - Create `Models/BugReport.swift` with `BugReport` struct
    - Create `Models/CrashReport.swift` with `CrashReport` struct
    - Create `Models/GroupChatMessage.swift` with `GroupChatMessage` struct
    - All models conform to `Codable`
    - _Requirements: 1.1, 1.2, 5.2, 7.3, 8.3, 9.3_

  - [ ] 1.3 Define the ChannelController protocol and ChannelControllerDelegate protocol
    - Create `Protocols/ChannelController.swift` with channelId, channelType, displayLabel, hasUnread, state, contentView, sendInput, activate, deactivate, retry, lastLines, commandHistory, delegate
    - Create `Protocols/ChannelControllerDelegate.swift` with channelDidReceiveOutput and channelStateDidChange
    - _Requirements: 1.2, 2.1, 2.3, 12.3_

- [ ] 2. Implement CommandHistory and core services
  - [ ] 2.1 Implement CommandHistory class
    - Create `Models/CommandHistory.swift` with entries array, cursor, maxEntries (100)
    - Implement add(), previous(), next(), reset() methods
    - _Requirements: 6.7, 6.8_

  - [ ]* 2.2 Write property test for CommandHistory navigation round-trip
    - **Property 17: Command history navigation round-trip**
    - **Validates: Requirements 6.7, 6.8**

  - [ ] 2.3 Implement AuthEnvironmentBuilder
    - Create `Services/AuthEnvironmentBuilder.swift`
    - Build minimal environment: PATH, HOME, SHELL, TERM, LANG
    - OAuth: explicitly omit ANTHROPIC_API_KEY
    - API key: inject ANTHROPIC_API_KEY with provided key
    - No parent environment inheritance
    - _Requirements: 4.1, 4.2, 4.3, 14.2, 14.3, 14.4_

  - [ ]* 2.4 Write property tests for AuthEnvironmentBuilder
    - **Property 8: OAuth environment omits API key**
    - **Property 9: API key environment injects correct key**
    - **Property 10: Clean environment contains only designated variables**
    - **Validates: Requirements 4.1, 4.2, 4.3, 14.2, 14.3, 14.4**

  - [ ] 2.5 Implement RoleDetector
    - Create `Services/RoleDetector.swift`
    - Parse CLAUDE.md for `> **You are the {role}**` pattern
    - Implement shortLabel() for tab abbreviations (e.g., "floor manager" → "FM")
    - Return nil when no match or file missing
    - _Requirements: 4.4, 4.5, 1.3_

  - [ ]* 2.6 Write property test for RoleDetector
    - **Property 11: CLAUDE.md role detection round-trip**
    - **Validates: Requirements 4.4, 1.3**

- [ ] 3. Checkpoint — Core models and services
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Implement ConfigService and persistence
  - [ ] 4.1 Implement ConfigService
    - Create `Services/ConfigService.swift`
    - Load from ~/.holoscape/config.json, save back
    - Handle missing file: create defaults
    - Handle malformed JSON: log warning, use defaults, overwrite on next save
    - Handle missing directory: create ~/.holoscape/
    - Handle permission errors: log error, use defaults, show non-blocking alert
    - _Requirements: 9.3, 9.4, 9.5, 10.1_

  - [ ]* 4.2 Write property tests for ConfigService
    - **Property 20: Config serialization round-trip**
    - **Property 21: Malformed config falls back to defaults**
    - **Property 22: Channel state persistence round-trip**
    - **Validates: Requirements 9.3, 9.5, 10.1, 10.2**

- [ ] 5. Implement ChannelManager
  - [ ] 5.1 Implement ChannelManager class
    - Create `Controllers/ChannelManager.swift`
    - Maintain channels dictionary, channelOrder array, instanceCounters
    - Implement createChannel(): assign instance number, add to registry, return controller
    - Implement closeChannel(): confirmation logic for active channels, remove from registry
    - Implement allChannels() returning ordered list
    - Implement moveUnreadToFront() for tab reordering
    - Implement saveState() and restoreState() using ConfigService
    - _Requirements: 1.2, 1.4, 1.5, 1.6, 2.4, 10.1, 10.2_

  - [ ]* 5.2 Write property tests for ChannelManager
    - **Property 1: Channel creation increments count and assigns instance number**
    - **Property 2: Sequential instance numbering for same-role channels**
    - **Property 3: Close confirmation iff running process**
    - **Property 6: Unread tabs reorder to leftmost**
    - **Validates: Requirements 1.2, 1.4, 1.5, 1.6, 2.4**

- [ ] 6. Implement ShellChannelController
  - [ ] 6.1 Implement ShellChannelController
    - Create `Controllers/ShellChannelController.swift` conforming to ChannelController
    - Wrap SwiftTerm `LocalProcessTerminalView` as contentView
    - On activate(): spawn /bin/zsh via PTY
    - sendInput() writes to PTY file descriptor
    - On process termination: transition to disconnected state
    - retry() respawns zsh
    - lastLines() extracts from SwiftTerm buffer
    - displayLabel returns "Shell" with instance number if needed
    - _Requirements: 3.1, 3.2, 3.4, 3.5, 3.6, 12.1, 12.3_

  - [ ]* 6.2 Write property test for channel state transitions
    - **Property 23: Backend loss transitions to disconnected state**
    - **Validates: Requirements 10.6, 12.3**

- [ ] 7. Implement AgentChannelController
  - [ ] 7.1 Implement AgentChannelController
    - Create `Controllers/AgentChannelController.swift` conforming to ChannelController
    - Wrap SwiftTerm `LocalProcessTerminalView` as contentView
    - On activate(): call AuthEnvironmentBuilder, call RoleDetector, spawn `claude` CLI in constructed environment
    - Handle Agent_Direct (OAuth) and Agent_API (API key) auth types
    - displayLabel uses detected role + context; floor manager shows project directory name
    - Default label "Agent" when no role detected and no user label
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 14.2, 14.3, 14.4_

  - [ ]* 7.2 Write property tests for Agent channel
    - **Property 4: Tab label contains role and context**
    - **Property 12: Floor manager context shows project directory**
    - **Validates: Requirements 2.1, 4.6**

- [ ] 8. Implement GroupChatChannelController
  - [ ] 8.1 Implement GroupChatChannelController
    - Create `Controllers/GroupChatChannelController.swift` conforming to ChannelController
    - Use custom read-only NSTextView (monospace) as contentView
    - On activate(): establish HTTP polling or WebSocket to Agent Chat API with X-API-Key header
    - Format incoming messages as `[HH:MM PM] sender: message body`
    - sendInput() POSTs to API with sender = "erik"
    - Display messages from all participants without filtering
    - Handle connection failures: display error, exponential backoff reconnect
    - Handle auth failures (401/403): display error, no auto-retry
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_

  - [ ]* 8.2 Write property tests for GroupChatChannelController
    - **Property 13: Group chat message formatting**
    - **Property 14: Group chat outbound sender is always "erik"**
    - **Property 15: Group chat displays all senders without filtering**
    - **Validates: Requirements 5.2, 5.3, 5.4**

- [ ] 9. Checkpoint — All channel controllers complete
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 10. Implement views and window layout
  - [ ] 10.1 Implement TabBarView
    - Create `Views/TabBarView.swift` as custom NSView
    - Render channel tabs horizontally with role label + context
    - Active tab visually distinct from inactive tabs
    - Unread dot indicator on tabs with hasUnread = true
    - Horizontal scrolling when tabs overflow visible width
    - Click to switch channels (notify delegate)
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.8_

  - [ ] 10.2 Implement InputBoxView
    - Create `Views/InputBoxView.swift` as NSTextView subclass
    - Click-to-position cursor, text selection (mouse drag, Shift+Arrow)
    - Delete/Backspace removes selected text
    - Cmd+A, Cmd+C, Cmd+V, Cmd+X support
    - Enter key: send text to active channel via delegate, clear input
    - Empty input on Enter: no-op
    - Up Arrow in empty input: recall previous command from per-channel history
    - Down Arrow while browsing history: navigate forward
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8_

  - [ ]* 10.3 Write property tests for InputBox and TabBar
    - **Property 5: Unread indicator lifecycle**
    - **Property 16: Enter sends input and clears**
    - **Validates: Requirements 2.3, 2.5, 5.6, 6.6**

  - [ ] 10.4 Implement TerminalContainerView
    - Create `Views/TerminalContainerView.swift`
    - Container that swaps in the active channel's contentView
    - Full-width monospace rendering area
    - _Requirements: 11.2, 11.3_

  - [ ] 10.5 Implement MainWindowController
    - Create `Controllers/MainWindowController.swift`
    - Single window: TabBarView (top), TerminalContainerView (center), InputBoxView (bottom)
    - Coordinate channel switching: update TabBar active state, swap contentView, clear unread
    - Support macOS native window transparency
    - Wire Cmd+W to close active channel
    - Wire Cmd+N to open channel type picker (modal sheet with Shell, Agent Direct, Agent API, Group Chat buttons)
    - _Requirements: 11.1, 11.2, 11.4, 2.2, 2.7, 1.1_

- [ ] 11. Implement BugReportService and CrashReportScanner
  - [ ] 11.1 Implement BugReportService
    - Create `Services/BugReportService.swift`
    - submitBugReport(): POST BugReport JSON to SIL API endpoint
    - submitCrashReport(): POST CrashReport JSON to SIL API endpoint
    - Handle success/error responses
    - _Requirements: 7.2, 7.5, 7.6_

  - [ ] 11.2 Implement CrashReportScanner
    - Create `Services/CrashReportScanner.swift`
    - Scan ~/Library/Logs/DiagnosticReports/ for Holoscape crash logs since last launch timestamp
    - Return list of crash logs with traces
    - _Requirements: 8.1, 8.4_

  - [ ]* 11.3 Write property tests for reporting
    - **Property 18: Report payloads contain required fields and no sensitive data**
    - **Property 19: Crash scanner filters by timestamp**
    - **Validates: Requirements 7.3, 7.4, 8.3, 8.5, 8.1**

  - [ ] 11.4 Implement bug report overlay UI
    - Wire Cmd+B to display one-line input overlay
    - On Enter: collect active channel name, type, last 20 lines, timestamp, macOS version, description
    - Submit via BugReportService
    - Show confirmation on success, show error on failure (keep overlay open on error)
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

  - [ ] 11.5 Implement crash detection prompt on launch
    - On app launch: run CrashReportScanner
    - If crash found: display prompt "Holoscape crashed. File a report?" with submit button
    - On submit: POST crash trace + last channel state via BugReportService
    - Record current launch timestamp in config
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

- [ ] 12. Implement appearance settings
  - [ ] 12.1 Implement appearance settings UI
    - Create settings interface (accessible via menu or Cmd+,)
    - Background color picker
    - Transparency slider (0.0 to 1.0)
    - Font family selector
    - Font size selector
    - ANSI color palette customization
    - _Requirements: 9.1, 9.6_

  - [ ] 12.2 Wire appearance settings to live preview and persistence
    - Apply changes in real time to active window
    - Save to ConfigService on change
    - Load and apply on launch before displaying window
    - _Requirements: 9.2, 9.3, 9.4_

- [ ] 13. Implement AppDelegate and application lifecycle
  - [ ] 13.1 Implement AppDelegate
    - Create `AppDelegate.swift`
    - On launch: load config, apply appearance, restore channels, run crash scanner
    - On normal exit: save channel state to config
    - Ensure startup completes within 2 seconds target
    - _Requirements: 9.4, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 13.1_

  - [ ] 13.2 Wire channel restoration logic
    - On launch: read saved ChannelMetadata from config
    - Recreate Shell channels with new zsh processes
    - Recreate Agent channels with correct auth isolation
    - Recreate Group Chat channels with API reconnection
    - Failed restores show disconnected state with retry/close options
    - _Requirements: 10.2, 10.3, 10.4, 10.5, 10.6_

- [ ] 14. Integration wiring and scrollback configuration
  - [ ] 14.1 Wire all components together end-to-end
    - Connect ChannelManager to MainWindowController
    - Connect TabBarView click events to channel switching
    - Connect InputBoxView Enter to active channel's sendInput
    - Connect channel output notifications to unread indicator updates
    - Connect unread transitions to tab reordering via ChannelManager.moveUnreadToFront
    - Ensure channel switching is instant with no re-rendering delay
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 6.6, 13.2_

  - [ ] 14.2 Implement configurable scrollback buffer
    - Add scrollback depth to AppearanceConfig or a separate config field
    - Apply scrollback limit to SwiftTerm views and group chat NSTextView
    - Discard oldest lines when buffer is full
    - _Requirements: 3.3, 5.5_

  - [ ]* 14.3 Write property test for scrollback buffer
    - **Property 7: Scrollback buffer respects configured depth**
    - **Validates: Requirements 3.3, 5.5**

- [ ] 15. Final checkpoint — Full integration
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- Swift/AppKit/SwiftTerm throughout; macOS Sequoia 15.0+ deployment target
