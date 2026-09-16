import Foundation

/// Newline-delimited stdio loop for the out-of-process broker host.
///
/// The app-side transport writes one request frame and waits for one response
/// frame. This server is the matching host-side loop: it preserves one response
/// per complete input line, keeps the broker process alive across requests, and
/// converts malformed protocol input into explicit failure frames instead of
/// silently exiting.
struct BrokerSessionHostStdioServer {
    private let host: BrokerSessionHost
    private let codec: BrokerSessionHostCodec
    private let input: FileHandle
    private let output: FileHandle
    private let readChunkSize: Int

    init(
        host: BrokerSessionHost,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        readChunkSize: Int = 4096
    ) {
        precondition(readChunkSize > 0, "Broker host stdio read chunk size must be positive")
        self.host = host
        self.codec = codec
        self.input = input
        self.output = output
        self.readChunkSize = readChunkSize
    }

    func runUntilEOF() throws {
        var buffer = Data()

        while true {
            let chunk = input.readData(ofLength: readChunkSize)
            if chunk.isEmpty {
                return
            }

            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer.prefix(through: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                try output.write(contentsOf: responseFrame(for: Data(frame)))
            }
        }
    }

    private func responseFrame(for frame: Data) -> Data {
        do {
            return try host.handle(frame)
        } catch {
            return protocolFailureFrame(for: error)
        }
    }

    private func protocolFailureFrame(for error: Error) -> Data {
        let response = BrokerSessionHostResponse.failure(
            BrokerSessionHostFailure(
                code: "protocol-error",
                message: String(describing: error)
            )
        )

        do {
            return try codec.encodeResponse(response)
        } catch {
            preconditionFailure("Broker host failed to encode protocol failure frame: \(error)")
        }
    }
}
