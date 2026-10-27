import Foundation

enum ComposerPresentationMode: String, Equatable, Sendable {
    case composer
    case rawTerminal
}

struct ComposerChannelState: Equatable, Sendable {
    var draft: String = ""
    var manualMode: ComposerPresentationMode?
    var alternateScreenActive = false

    var effectiveMode: ComposerPresentationMode {
        manualMode ?? (alternateScreenActive ? .rawTerminal : .composer)
    }
}

@MainActor
final class ComposerChannelStateStore {
    private var states: [UUID: ComposerChannelState] = [:]

    func state(for channelId: UUID) -> ComposerChannelState {
        states[channelId] ?? ComposerChannelState()
    }

    func update(_ state: ComposerChannelState, for channelId: UUID) {
        states[channelId] = state
    }

    func updateDraft(_ draft: String, for channelId: UUID) {
        var state = state(for: channelId)
        state.draft = draft
        update(state, for: channelId)
    }

    func updateManualMode(_ mode: ComposerPresentationMode, for channelId: UUID) {
        var state = state(for: channelId)
        state.manualMode = mode
        update(state, for: channelId)
    }

    func updateAlternateScreenActive(_ active: Bool, for channelId: UUID) {
        var state = state(for: channelId)
        state.alternateScreenActive = active
        update(state, for: channelId)
    }

    func removeState(for channelId: UUID) {
        states.removeValue(forKey: channelId)
    }

    var count: Int { states.count }
}
