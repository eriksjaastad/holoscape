import Foundation

/// Request dispatcher for the out-of-process broker host protocol.
///
/// The host owns a `BrokerSessionRuntime`, accepts one newline-delimited request
/// frame, and returns one newline-delimited response frame. It intentionally
/// keeps runtime errors inside protocol failure frames so the app-side client can
/// fail loudly with a broker-specific message instead of losing the connection
/// context.
struct BrokerSessionHost {
    private let runtime: any BrokerSessionRuntime
    private let codec: BrokerSessionHostCodec

    init(runtime: any BrokerSessionRuntime, codec: BrokerSessionHostCodec = BrokerSessionHostCodec()) {
        self.runtime = runtime
        self.codec = codec
    }

    func handle(_ frame: Data) throws -> Data {
        let request = try codec.decodeRequest(frame)
        let response: BrokerSessionHostResponse
        do {
            response = try dispatch(request)
        } catch {
            response = .failure(
                BrokerSessionHostFailure(
                    code: "runtime-error",
                    message: String(describing: error)
                )
            )
        }
        return try codec.encodeResponse(response)
    }

    private func dispatch(_ request: BrokerSessionHostRequest) throws -> BrokerSessionHostResponse {
        switch request {
        case .listSessions:
            return .sessionIDs(try runtime.listSessions())
        case let .create(id, launchRequest):
            try runtime.createSession(id: id, request: launchRequest)
            return .ok
        case let .detach(id):
            try runtime.detachSession(id: id)
            return .ok
        case let .attach(id, channelID):
            try runtime.attachSession(id: id, channelID: channelID)
            return .ok
        case let .terminate(id, exitCode):
            try runtime.terminateSession(id: id, exitCode: exitCode)
            return .ok
        case let .markErrored(id):
            try runtime.markSessionErrored(id: id)
            return .ok
        case let .sendInput(id, bytes):
            try runtime.sendInput(id: id, bytes: Array(bytes))
            return .ok
        case let .readAvailableOutput(id):
            return .output(try runtime.readAvailableOutput(id: id))
        case let .readScrollbackTail(id, maxBytes):
            return .output(try runtime.readScrollbackTail(id: id, maxBytes: maxBytes))
        case let .resize(id, size):
            try runtime.resizeSession(id: id, size: size)
            return .ok
        case let .isRunning(id):
            return .running(try runtime.isRunning(id: id))
        case let .terminationStatus(id):
            return .terminationStatus(try runtime.terminationStatus(id: id))
        }
    }
}
