import Foundation
import os

/// Shared state source for both the Metal shader layer and the chrome
/// skinning layer. Lock-protected reads and writes provide thread-safe
/// access from any thread. Designed as `@unchecked Sendable` so it can
/// be shared across actor boundaries (Metal rendering runs off-main,
/// chrome rendering runs on main).
///
/// Field set mirrors the Holoscape extension uniforms declared in
/// `docs/skins/05-reactive-uniforms.md` §5. The GLSL-side `i` prefix is
/// dropped here because Swift code has no use for the GLSL naming
/// convention.
///
/// Initial implementation uses `OSAllocatedUnfairLock` (macOS 13+) which
/// provides sub-microsecond acquire/release for uncontended cases — fine
/// for state that changes on event transitions, not per frame.
final class ReactiveUniformSnapshot: @unchecked Sendable {
    // MARK: - Agent state
    var agentState: Int32 { lock.withLock { _agentState } }
    var previousAgentState: Int32 { lock.withLock { _previousAgentState } }
    var timeAgentStateChange: Double { lock.withLock { _timeAgentStateChange } }

    // MARK: - Command lifecycle
    var commandState: Int32 { lock.withLock { _commandState } }
    var previousCommandState: Int32 { lock.withLock { _previousCommandState } }
    var lastCommandExitCode: Int32 { lock.withLock { _lastCommandExitCode } }
    var timeCommandStart: Double { lock.withLock { _timeCommandStart } }
    var timeCommandEnd: Double { lock.withLock { _timeCommandEnd } }

    // MARK: - Channel state
    var channelId: Int32 { lock.withLock { _channelId } }
    var channelIsActive: Int32 { lock.withLock { _channelIsActive } }
    var channelUnread: Int32 { lock.withLock { _channelUnread } }

    // MARK: - Output / notification
    var outputEventCount: Int32 { lock.withLock { _outputEventCount } }
    var timeLastOutput: Double { lock.withLock { _timeLastOutput } }
    var notificationKind: Int32 { lock.withLock { _notificationKind } }
    var timeLastNotification: Double { lock.withLock { _timeLastNotification } }

    // MARK: - Mutation

    /// Update agent state. Stamps `timeAgentStateChange` on every transition
    /// (both directions) so animations can fire consistently.
    func setAgentState(_ newValue: Int32) {
        lock.withLock {
            if _agentState != newValue {
                _previousAgentState = _agentState
                _agentState = newValue
                _timeAgentStateChange = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    /// Update command state. Stamps `timeCommandStart` on idle→running and
    /// `timeCommandEnd` on running→completed.
    func setCommandState(_ newValue: Int32, exitCode: Int32 = 0) {
        lock.withLock {
            guard _commandState != newValue else { return }
            _previousCommandState = _commandState
            _commandState = newValue
            let now = CFAbsoluteTimeGetCurrent()
            if newValue == 1 {
                _timeCommandStart = now
            } else if newValue == 2 {
                _timeCommandEnd = now
                _lastCommandExitCode = exitCode
            }
        }
    }

    /// Update channel state (stable channel hash + active flag + unread count).
    func setChannelState(channelId: Int32, isActive: Int32, unread: Int32) {
        lock.withLock {
            _channelId = channelId
            _channelIsActive = isActive
            _channelUnread = unread
        }
    }

    /// Stamp a new output event. Callers increment `outputEventCount`; we
    /// record the timestamp.
    func recordOutputEvent() {
        lock.withLock {
            _outputEventCount = _outputEventCount &+ 1
            _timeLastOutput = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Post a notification state. `kind` follows the GLSL enum:
    /// 0=none, 1=info, 2=warn, 3=error.
    func postNotification(kind: Int32) {
        lock.withLock {
            _notificationKind = kind
            _timeLastNotification = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Clear a notification (set to kind 0). Does NOT stamp the timestamp —
    /// callers checking `timeSince(iTimeLastNotification)` see the last
    /// time a notification was *posted*, not cleared.
    func clearNotification() {
        lock.withLock {
            _notificationKind = 0
        }
    }

    /// Explicit timestamp stamp for a named field. Used by integration
    /// points that want to record a transition without going through the
    /// typed setters above (e.g., synthetic test scenarios).
    func stampTransition(_ field: TimestampField) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            switch field {
            case .agentStateChange: _timeAgentStateChange = now
            case .lastOutput: _timeLastOutput = now
            case .lastNotification: _timeLastNotification = now
            case .commandStart: _timeCommandStart = now
            case .commandEnd: _timeCommandEnd = now
            }
        }
    }

    /// Read a Double-valued field by its GLSL uniform name. Used by the
    /// `timeSince` match operator.
    func timestamp(named name: String) -> Double? {
        lock.withLock {
            switch name {
            case "iTimeAgentStateChange": return _timeAgentStateChange
            case "iTimeLastOutput": return _timeLastOutput
            case "iTimeLastNotification": return _timeLastNotification
            case "iTimeCommandStart": return _timeCommandStart
            case "iTimeCommandEnd": return _timeCommandEnd
            default: return nil
            }
        }
    }

    /// Read an Int32-valued field by its JSON match key (with the `i`
    /// prefix dropped). Returns nil for unknown keys — the evaluator
    /// logs and skips unknown match conditions.
    func intValue(forMatchKey key: String) -> Int32? {
        lock.withLock {
            switch key {
            case "agentState": return _agentState
            case "previousAgentState": return _previousAgentState
            case "commandState": return _commandState
            case "previousCommandState": return _previousCommandState
            case "lastCommandExitCode": return _lastCommandExitCode
            case "channelId": return _channelId
            case "channelIsActive": return _channelIsActive
            case "channelUnread": return _channelUnread
            case "notificationKind": return _notificationKind
            case "outputEventCount": return _outputEventCount
            default: return nil
            }
        }
    }

    // MARK: - Timestamp field identifier

    enum TimestampField {
        case agentStateChange
        case lastOutput
        case lastNotification
        case commandStart
        case commandEnd
    }

    // MARK: - Storage

    private let lock = OSAllocatedUnfairLock()

    private var _agentState: Int32 = 0
    private var _previousAgentState: Int32 = 0
    private var _timeAgentStateChange: Double = 0

    private var _commandState: Int32 = 0
    private var _previousCommandState: Int32 = 0
    private var _lastCommandExitCode: Int32 = 0
    private var _timeCommandStart: Double = 0
    private var _timeCommandEnd: Double = 0

    private var _channelId: Int32 = 0
    private var _channelIsActive: Int32 = 0
    private var _channelUnread: Int32 = 0

    private var _outputEventCount: Int32 = 0
    private var _timeLastOutput: Double = 0
    private var _notificationKind: Int32 = 0
    private var _timeLastNotification: Double = 0
}
