# Implementation Plan: Holoscape V2 Features

## Overview

Incremental update to the existing Holoscape V1+V1.5 app. Tasks modify and extend existing Swift/AppKit code — no rebuild. The implementation proceeds bottom-up: extend models and enums first, then add new services/utilities, then new controllers, then modify existing controllers and views, then wire everything into MainWindowController. Each task builds on the previous and ends with integration.

## Tasks

- [ ] 1. Extend data models and enums for V2
  - [ ] 1.1 Add `.mcp` and `.agentChat` cases to ConnectionType and `.mcp` to ChannelType
    - In `Sources/Holoscape/Models/SessionProfile.swift`, add `case mcp` and `case agentChat` to the `ConnectionType` enum
    - In `Sources/Holoscape/Models/ChannelType.swift`, add `case mcp` to the `ChannelType` enum
    - _Requirements: 7.1_

  - [ ] 1.2 Add V2 fields to SessionProfile
    - In `Sources/Holoscape/Models/SessionProfile.swift`, add optional fields to `SessionProfile`: `endpoint: String?` (MCP), `apiURL: String?` (agent-chat), `apiKeyEnv: String?` (agent-chat)
    - All new fields must be `Optional` so V1.5 config files decode without error
    - _Requirements: 7.2, 7.3_

  - [ ] 1.3 Add V2 fields to AppearanceConfig and HoloscapeConfig
    - In `Sources/Holoscape/Models/HoloscapeConfig.swift`, add `themeName: String?` and `themeOverrides: [String: String]?` to `AppearanceConfig`
    - Add `showTimestamps: Bool?` to `HoloscapeConfig`
    - _Requirements: 8.1, 8.2, 8.3_

  - [ ] 1.4 Add V2 fields to ChannelMetadata for MCP/GroupChat persistence
    - In `Sources/Holoscape/Models/ChannelMetadata.swift`, add optional fields: `endpoint: String?`, `apiURL: String?`, `apiKeyEnv: String?`
    - Update the `init` to accept these new parameters with default nil values
    - _Requirements: 9.1_

  - [ ]* 1.5 Write property tests for V2 config round-trip and backward compatibility
    - **Property 1: V2 Config serialization round-trip** — generate random `HoloscapeConfig` with V1+V1.5+V2 fields (including MCP and agent-chat SessionProfiles), verify `decode(encode(config)) == config`
    - **Validates: Requirements 7.4, 8.5**
    - **Property 2: V1.5 config backward compatibility with V2** — generate V1.5-only configs, encode, decode as V2, verify V1.5 fields preserved and V2 fields nil
    - **Validates: Requirements 8.4**
    - Create `Tests/HoloscapePropertyTests/ConfigV2RoundTripPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ConfigV2BackwardCompatPropertyTests.swift`

  - [ ]* 1.6 Write property test for ConnectionType enum round-trip
    - **Property 17: ConnectionType enum round-trip** — for all `ConnectionType` cases (including `.mcp` and `.agentChat`), verify `ConnectionType(rawValue: case.rawValue) == case`
    - **Validates: Requirements 7.1**
    - Create `Tests/HoloscapePropertyTests/ConnectionTypeRoundTripPropertyTests.swift`

  - [ ]* 1.7 Write unit tests for V2 model extensions
    - Create `Tests/HoloscapeTests/Unit/SessionProfileV2Tests.swift` — test encoding/decoding MCP profile with endpoint, agent-chat profile with apiURL and apiKeyEnv, and that V1.5 profiles still decode correctly
    - Create `Tests/HoloscapeTests/Unit/ConnectionTypeV2Tests.swift` — test `.mcp` and `.agentChat` raw values and JSON decoding
    - Create `Tests/HoloscapeTests/Unit/ConfigV2BackwardCompatTests.swift` — test decoding a V1.5 JSON string as V2 config, verify V2 fields are nil
    - Create `Tests/HoloscapeTests/Unit/ChannelMetadataV2Tests.swift` — test encoding/decoding metadata with endpoint, apiURL, apiKeyEnv fields
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 8.4, 8.5, 9.1_

- [ ] 2. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 3. Implement new V2 services and utilities
  - [ ] 3.1 Create ColorTheme struct with 6 built-in themes
    - Create `Sources/Holoscape/Services/ColorTheme.swift`
    - Define `ColorTheme` struct with `name`, `background`, `foreground`, `ansiColors` (16-entry array)
    - Add static constants for Dark, Monokai, Solarized Dark, Solarized Light, Dracula, Nord
    - Add `static let allThemes` array and `static func named(_ name: String) -> ColorTheme?`
    - Add `func apply(to config: AppearanceConfig, overrides: [String: String]?) -> AppearanceConfig` method
    - _Requirements: 5.1, 5.2_

  - [ ] 3.2 Create TimestampInjector utility
    - Create `Sources/Holoscape/Services/TimestampInjector.swift`
    - Implement `static func prefix(for date: Date) -> String` returning `[HH:MM:SS] ` format
    - Implement `static func addSeconds(to formattedMessage: String, date: Date) -> String` that transforms `[H:MM AM/PM]` to `[H:MM:SS AM/PM]` in group chat messages
    - _Requirements: 4.1, 4.6_

  - [ ] 3.3 Create ElapsedTimeFormatter utility
    - Create `Sources/Holoscape/Services/ElapsedTimeFormatter.swift`
    - Implement `static func format(since activatedAt: Date?) -> String?` returning `"Xh Ym"` or `"Ym"` format
    - _Requirements: 3.1, 3.4_

  - [ ] 3.4 Create MCPClient actor
    - Create `Sources/Holoscape/Services/MCPClient.swift`
    - Implement `actor MCPClient` with `init(endpoint: URL)`, `func initialize() async throws`, `func sendMessage(_ text: String) async throws -> String`
    - Use HTTP POST with JSON-RPC 2.0 format for `initialize` and `tools/call` methods
    - Send `notifications/initialized` after successful handshake
    - Define `MCPError` enum: `.notInitialized`, `.connectionFailed`, `.invalidResponse`
    - _Requirements: 1.2, 1.3, 1.4_

  - [ ]* 3.5 Write property tests for V2 utilities
    - **Property 9: Timestamp prefix format** — generate random Date values, verify `TimestampInjector.prefix(for:)` matches `[HH:MM:SS] ` pattern
    - **Validates: Requirements 4.1**
    - **Property 10: Group chat timestamp seconds precision** — generate random formatted group chat messages with timestamps, verify `addSeconds` produces correct `[H:MM:SS AM/PM]` format
    - **Validates: Requirements 4.6**
    - **Property 8: Elapsed time formatting** — generate random activation timestamps in the past, verify elapsed time string format and correctness
    - **Validates: Requirements 3.1, 3.7**
    - **Property 11: Theme structure completeness** — iterate all `ColorTheme.allThemes`, verify each has non-empty name, valid hex background/foreground, and exactly 16 ANSI colors
    - **Validates: Requirements 5.2**
    - **Property 12: Theme application with overrides** — generate random themes and override dictionaries, verify `apply(to:overrides:)` produces correct merged result
    - **Validates: Requirements 5.4, 5.7**
    - **Property 13: Theme switch clears overrides** — generate random configs with theme and overrides, simulate theme switch, verify overrides are cleared
    - **Validates: Requirements 5.8**
    - Create `Tests/HoloscapePropertyTests/TimestampPrefixPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/TimestampSecondsPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ElapsedTimePropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ThemeCompletenessPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ThemeApplicationPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ThemeSwitchPropertyTests.swift`

  - [ ]* 3.6 Write unit tests for V2 utilities
    - Create `Tests/HoloscapeTests/Unit/ColorThemeTests.swift` — test all 6 themes exist, `named("Dracula")` returns correct theme, `named("nonexistent")` returns nil, `apply` with and without overrides
    - Create `Tests/HoloscapeTests/Unit/TimestampInjectorTests.swift` — test `prefix(for:)` with midnight, noon, 11:59:59 PM; test `addSeconds(to:date:)` with specific formatted messages
    - Create `Tests/HoloscapeTests/Unit/ElapsedTimeFormatterTests.swift` — test 0 minutes → "0m", 65 minutes → "1h 5m", 120 minutes → "2h 0m", nil → nil
    - _Requirements: 3.1, 4.1, 4.6, 5.1, 5.2, 5.4, 5.7, 5.8_

- [ ] 4. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 5. Implement MCPChannelController
  - [ ] 5.1 Create MCPChannelController
    - Create `Sources/Holoscape/Controllers/MCPChannelController.swift`
    - Implement `ChannelController` protocol with `channelType = .mcp`
    - Use read-only `NSTextView` with monospace font as `contentView` (same pattern as `GroupChatChannelController`)
    - Implement `activate()`: set state to `.connecting`, call `mcpClient.initialize()` async, on success set state to `.active` and record `activatedAt`, on failure set state to `.disconnected` and display error
    - Implement `sendInput()`: display outgoing message as `[H:MM AM/PM] erik: text`, call `mcpClient.sendMessage()` async, display response as `[H:MM AM/PM] CEO: response`
    - Implement `deactivate()`, `retry()`, `lastLines()`, `displayLabel` (label + optional instance number)
    - Store `activatedAt: Date?` for elapsed time display
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10_

  - [ ]* 5.2 Write property tests for MCP message formatting and display label
    - **Property 3: MCP and Group Chat message formatting** — generate random sender/body/timestamp triples, verify formatted output matches `[H:MM AM/PM] sender: body` pattern
    - **Validates: Requirements 1.5, 2.4**
    - **Property 4: MCP/GroupChat display label format** — generate random labels and optional instance numbers, verify `displayLabel` equals `"L N"` when N is non-nil, or `"L"` when N is nil
    - **Validates: Requirements 1.10**
    - Create `Tests/HoloscapePropertyTests/MessageFormattingPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/DisplayLabelV2PropertyTests.swift`

  - [ ]* 5.3 Write unit tests for MCPChannelController and MCPClient
    - Create `Tests/HoloscapeTests/Unit/MCPChannelControllerTests.swift` — test construction with specific endpoint URL, test `displayLabel` with label "CEO" and instance number nil vs 2, test `sendInput` with empty string (no-op), test state transitions
    - Create `Tests/HoloscapeTests/Unit/MCPClientTests.swift` — test JSON-RPC request construction for `initialize` and `tools/call`, test error handling for non-200 responses
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.7, 1.8, 1.10_

- [ ] 6. Modify GroupChatChannelController for V2
  - [ ] 6.1 Refactor GroupChatChannelController for SessionProfile-based construction
    - In `Sources/Holoscape/Controllers/GroupChatChannelController.swift`:
    - Add `profileLabel: String` and `instanceNumber: Int?` private fields
    - Add new initializer: `init(id: UUID, apiURL: String, apiKey: String, label: String, instanceNumber: Int?)`
    - Change `displayLabel` from hardcoded `"Chat"` to use `profileLabel` + optional instance number
    - Add `activatedAt: Date?` property, set it when first successful poll transitions state to `.active`
    - Add auto-scroll check: only auto-scroll if scroll view is at bottom (check `scrollView.contentView.bounds` vs `documentView` height)
    - Keep existing `init(id:apiURL:apiKey:)` as convenience initializer for backward compat
    - _Requirements: 2.1, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.11, 2.12_

  - [ ]* 6.2 Write property tests for group chat behavior
    - **Property 5: Group chat displays all senders without filtering** — generate random sender identifier strings, create messages, verify all are rendered without filtering
    - **Validates: Requirements 2.5**
    - **Property 6: Group chat outbound sender is always "erik"** — generate random message texts, verify outbound payload sender is always "erik"
    - **Validates: Requirements 2.6**
    - **Property 7: Exponential backoff delay sequence** — generate random failure counts (1-20), verify backoff delay follows `min(2^(K-1), 30)`
    - **Validates: Requirements 2.12**
    - Create `Tests/HoloscapePropertyTests/SenderFilterPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/OutboundSenderPropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/BackoffDelayPropertyTests.swift`

  - [ ]* 6.3 Write unit tests for GroupChatChannelController V2 changes
    - Create `Tests/HoloscapeTests/Unit/GroupChatV2Tests.swift` — test construction from SessionProfile fields, test `displayLabel` with label "Group Chat" and instance numbers, test auto-scroll logic, test auth failure handling (401 response)
    - _Requirements: 2.4, 2.9, 2.11_

- [ ] 7. Extend ChannelManager for V2 channel creation and persistence
  - [ ] 7.1 Add `.mcp` and `.agentChat` dispatch to ChannelManager.createChannel(from:)
    - In `Sources/Holoscape/Controllers/ChannelManager.swift`:
    - Add `case .mcp` to the switch in `createChannel(from:)`: validate `profile.endpoint` is non-nil and a valid URL, create `MCPChannelController`
    - Add `case .agentChat` to the switch: load API key via `loadAPIKey(envVarName:)`, create `GroupChatChannelController` with V2 initializer
    - Add `private func loadAPIKey(envVarName: String?) -> String` that checks env var first, then falls back to `~/.claude/agent-chat.env`
    - Add validation: skip MCP profiles with nil/empty endpoint, skip agent-chat profiles with nil/empty apiURL (log warning)
    - Add `defaultRole` case for `.mcp` returning `"MCP"`
    - _Requirements: 1.2, 2.2, 7.5, 7.6_

  - [ ] 7.2 Extend saveState/restoreState for MCP and GroupChat channel metadata
    - In `saveState()`: extract endpoint for MCP channels, extract apiURL/apiKeyEnv for GroupChat channels, include in `ChannelMetadata`
    - In `restoreState()`: handle `.mcp` and `.groupChat` types by reconstructing controllers from saved metadata
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [ ]* 7.3 Write property tests for V2 channel persistence and invalid profiles
    - **Property 15: Invalid profile validation** — generate random MCP profiles with nil/empty endpoint and agent-chat profiles with nil/empty apiURL, verify they are identified as invalid
    - **Validates: Requirements 7.5, 7.6**
    - **Property 16: MCP and Group Chat channel metadata persistence round-trip** — generate random `ChannelMetadata` lists with MCP and group chat entries, verify save/load round-trip preserves order and values
    - **Validates: Requirements 9.1**
    - Create `Tests/HoloscapePropertyTests/InvalidProfilePropertyTests.swift`
    - Create `Tests/HoloscapePropertyTests/ChannelMetadataV2RoundTripPropertyTests.swift`

  - [ ]* 7.4 Write unit tests for ChannelManager V2 changes
    - Create `Tests/HoloscapeTests/Unit/ChannelManagerV2Tests.swift` — test `createChannel(from:)` with MCP profile creates MCPChannelController, test with agent-chat profile creates GroupChatChannelController, test MCP profile with nil endpoint is skipped, test agent-chat profile with nil apiURL is skipped, test MCP/GroupChat metadata save/restore round-trip
    - _Requirements: 1.2, 2.2, 7.5, 7.6, 9.1, 9.2, 9.3_

- [ ] 8. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 9. Add process indicators and elapsed time to SidebarView and TabBarView
  - [ ] 9.1 Modify SidebarTabEntry to display elapsed time and state text
    - In `Sources/Holoscape/Views/SidebarView.swift`:
    - Add `elapsedLabel: NSTextField` to `SidebarTabEntry`
    - Extend `configure()` to accept `elapsedTime: String?` parameter
    - For `.active` state: show green dot + elapsed time string
    - For `.connecting` state: show yellow dot + "connecting..."
    - For `.disconnected` state: show red dot + "disconnected"
    - Update `SidebarView.updateTabs()` to pass elapsed time from `ElapsedTimeFormatter.format(since: channel.activatedAt)`
    - _Requirements: 3.1, 3.2, 3.3, 3.5, 3.6_

  - [ ] 9.2 Modify TabBarView to display elapsed time and colored state dots
    - In `Sources/Holoscape/Views/TabBarView.swift`:
    - Add elapsed time display and colored state dots matching the SidebarTabEntry pattern
    - _Requirements: 3.5_

  - [ ] 9.3 Add `activatedAt` protocol extension and update PTY-based controllers
    - Add `extension ChannelController { var activatedAt: Date? { nil } }` in `Sources/Holoscape/Protocols/ChannelController.swift`
    - In `ShellChannelController`, `AgentChannelController`, `SSHChannelController`: add `private(set) var activatedAt: Date?` property, set it when state transitions to `.active`
    - _Requirements: 3.7_

- [ ] 10. Add color theme dropdown to AppearanceSettingsWindowController
  - [ ] 10.1 Add theme dropdown and override logic to appearance settings
    - In `Sources/Holoscape/Views/AppearanceSettingsView.swift`:
    - Add `themePopup: NSPopUpButton` populated with `ColorTheme.allThemes.map(\.name)`
    - Insert theme row at top of settings stack
    - On theme selection: clear `themeOverrides`, set `themeName`, apply theme colors via `ColorTheme.apply(to:overrides:)`, save config
    - On individual color change (e.g., `colorChanged`): store change as a theme override in `themeOverrides` dictionary, save config
    - On launch: select the current `themeName` in the dropdown (or "Dark" if nil)
    - _Requirements: 5.3, 5.4, 5.5, 5.6, 5.7, 5.8_

- [ ] 11. Add keyboard shortcuts and timestamp toggle to MainWindowController
  - [ ] 11.1 Add Cmd+1-9 channel switching via local event monitor
    - In `Sources/Holoscape/Controllers/MainWindowController.swift`:
    - Add `private var keyMonitor: Any?` and `setupChannelSwitchShortcuts()` method
    - Register `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that checks for `.command` modifier + digit key codes 18-26 (keys 1-9)
    - Map key code to position (1-9), switch to Nth channel if it exists, consume event; otherwise pass through
    - Call `setupChannelSwitchShortcuts()` from `windowDidLoad()` or equivalent init
    - Remove monitor in `deinit` via `NSEvent.removeMonitor`
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6_

  - [ ] 11.2 Add Cmd+T timestamp toggle menu item
    - In `MainWindowController`:
    - Add "Show Timestamps" menu item under View menu with key equivalent "t"
    - Implement `toggleTimestamps()`: toggle `config.showTimestamps`, save to config, notify channels to update display
    - _Requirements: 4.3, 4.4_

  - [ ] 11.3 Add 60-second elapsed time refresh timer
    - In `MainWindowController`:
    - Add `private var elapsedTimeTimer: Timer?`
    - Start timer in `windowDidLoad()` with 60-second interval that calls `refreshAllTabs()` to update elapsed time display on all sidebar/tab bar entries
    - Invalidate timer in `deinit`
    - _Requirements: 3.4_

  - [ ]* 11.4 Write property test for Cmd+N channel switching
    - **Property 14: Cmd+N channel switching by position** — generate random channel lists (1-15 channels) and random N (1-9), verify: N ≤ count → switch to Nth channel, N > count → no change
    - **Validates: Requirements 6.2, 6.4**
    - Create `Tests/HoloscapePropertyTests/ChannelSwitchPropertyTests.swift`

  - [ ]* 11.5 Write unit tests for keyboard shortcuts
    - Create `Tests/HoloscapeTests/Unit/KeyboardShortcutTests.swift` — test Cmd+1 with 3 channels switches to first, test Cmd+5 with 3 channels does nothing, test digit-to-keycode mapping covers 1-9
    - _Requirements: 6.1, 6.2, 6.4_

- [ ] 12. Wire timestamp injection into channel output
  - [ ] 12.1 Integrate TimestampInjector into channel controllers
    - For PTY-based channels (`ShellChannelController`, `AgentChannelController`, `SSHChannelController`): intercept terminal output delegate callbacks, prepend `TimestampInjector.prefix(for:)` to each new line when `showTimestamps` is enabled (read from ConfigService)
    - For `MCPChannelController`: in `appendMessage()`, conditionally prepend timestamp prefix when `showTimestamps` is enabled
    - For `GroupChatChannelController`: in `appendMessage()`, use `TimestampInjector.addSeconds(to:date:)` to add seconds precision to existing timestamps when `showTimestamps` is enabled
    - _Requirements: 4.1, 4.2, 4.5, 4.6, 4.7_

- [ ] 13. Wire MCP and GroupChat channel restoration in AppDelegate
  - [ ] 13.1 Update AppDelegate to persist and restore MCP/GroupChat channels
    - On app exit: `channelManager.saveState()` now includes MCP and GroupChat metadata (handled by task 7.2)
    - On app launch: `channelManager.restoreState()` factory handles `.mcp` and `.groupChat` types, attempts reconnection
    - Display restored channels in disconnected state if reconnection fails, with retry option
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

- [ ] 14. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- All tasks modify/extend the existing V1+V1.5 codebase — no files are rebuilt from scratch
