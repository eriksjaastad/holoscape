import Foundation

/// Explicit retention policy for broker-owned terminal scrollback.
///
/// Privacy contract for #7171/#5884:
/// - broker session records, channel config, and IPC frames store launch metadata only;
/// - raw terminal bytes are retained only in the broker runtime scrollback ring;
/// - the ring is bounded per session and older bytes are dropped FIFO;
/// - reattach/relaunch replays at most the same bounded tail into the terminal view;
/// - Holoscape does not redact terminal output, so users should treat anything
///   printed to a terminal as restorable until it ages out of this per-session cap.
struct ScrollbackPersistencePolicy: Equatable, Sendable {
    static let maxRetainedBytesPerSession = 1_048_576
    static let maxReplayBytesOnReattach = maxRetainedBytesPerSession

    private init() {}
}
