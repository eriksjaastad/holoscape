import Foundation

/// JSON-lines protocol shared by the app-side broker client and the future
/// out-of-process Holoscape session broker host.
///
/// The protocol mirrors `BrokerSessionRuntime` exactly so moving PTY ownership
/// out of the UI process does not add a second lifecycle vocabulary. Launch
/// messages carry a `BrokerEnvironmentProfile` instead of raw environment
/// key/value pairs to keep secrets out of durable IPC logs and crash artifacts.
enum BrokerSessionHostRequest: Codable, Equatable, Sendable {
    case create(id: BrokerSessionID, request: BrokerSessionLaunchRequest)
    case detach(id: BrokerSessionID)
    case attach(id: BrokerSessionID, channelID: UUID)
    case terminate(id: BrokerSessionID, exitCode: Int32?)
    case markErrored(id: BrokerSessionID)
    case sendInput(id: BrokerSessionID, bytes: Data)
    case readAvailableOutput(id: BrokerSessionID)
    case resize(id: BrokerSessionID, size: TerminalGridSize)
    case isRunning(id: BrokerSessionID)
    case terminationStatus(id: BrokerSessionID)
}

enum BrokerSessionHostResponse: Codable, Equatable, Sendable {
    case ok
    case output(Data)
    case running(Bool)
    case terminationStatus(Int32?)
    case failure(BrokerSessionHostFailure)
}

struct BrokerSessionHostFailure: Codable, Equatable, Sendable {
    let code: String
    let message: String

    init(code: String, message: String) {
        precondition(!code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Broker host failure code cannot be empty")
        precondition(!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Broker host failure message cannot be empty")
        self.code = code
        self.message = message
    }
}

struct BrokerSessionHostCodec: Sendable {
    enum CodecError: Error, Equatable {
        case emptyFrame
        case nonUTF8Frame
    }

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func encodeRequest(_ request: BrokerSessionHostRequest) throws -> Data {
        try encodeFrame(request)
    }

    func decodeRequest(_ frame: Data) throws -> BrokerSessionHostRequest {
        try decodeFrame(BrokerSessionHostRequest.self, from: frame)
    }

    func encodeResponse(_ response: BrokerSessionHostResponse) throws -> Data {
        try encodeFrame(response)
    }

    func decodeResponse(_ frame: Data) throws -> BrokerSessionHostResponse {
        try decodeFrame(BrokerSessionHostResponse.self, from: frame)
    }

    private func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func decodeFrame<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        var payload = frame
        if payload.last == 0x0A {
            payload.removeLast()
        }
        guard !payload.isEmpty else {
            throw CodecError.emptyFrame
        }
        guard String(data: payload, encoding: .utf8) != nil else {
            throw CodecError.nonUTF8Frame
        }
        return try decoder.decode(type, from: payload)
    }
}
