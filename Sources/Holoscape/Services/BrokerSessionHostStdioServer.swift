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
    private let maximumFrameSize: Int

    init(
        host: BrokerSessionHost,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        readChunkSize: Int = 4096,
        maximumFrameSize: Int = BrokerSessionHostProtocolLimits.maximumRequestFrameSize
    ) {
        precondition(readChunkSize > 0, "Broker host stdio read chunk size must be positive")
        precondition(maximumFrameSize > 0, "Broker host stdio maximum frame size must be positive")
        self.host = host
        self.codec = codec
        self.input = input
        self.output = output
        self.readChunkSize = readChunkSize
        self.maximumFrameSize = maximumFrameSize
    }

    func runUntilEOF() throws {
        var buffer = Data()
        var discardingOversizedFrame = false

        while true {
            let chunk = input.readData(ofLength: readChunkSize)
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    try output.write(
                        contentsOf: protocolFailureFrame(
                            for: BrokerSessionHostProtocolError.truncatedFrame
                        )
                    )
                }
                return
            }

            var offset = chunk.startIndex
            while offset < chunk.endIndex {
                if discardingOversizedFrame {
                    guard let newlineIndex = chunk[offset...].firstIndex(of: 0x0A) else {
                        break
                    }
                    discardingOversizedFrame = false
                    offset = chunk.index(after: newlineIndex)
                    continue
                }

                if let newlineIndex = chunk[offset...].firstIndex(of: 0x0A) {
                    let end = chunk.index(after: newlineIndex)
                    let segment = chunk[offset..<end]
                    if segment.count > maximumFrameSize - buffer.count {
                        try writeOversizedFrameFailure()
                        buffer.removeAll(keepingCapacity: false)
                    } else {
                        buffer.append(contentsOf: segment)
                        try output.write(contentsOf: responseFrame(for: buffer))
                        buffer.removeAll(keepingCapacity: true)
                    }
                    offset = end
                    continue
                }

                let segment = chunk[offset...]
                if segment.count > maximumFrameSize - buffer.count {
                    try writeOversizedFrameFailure()
                    buffer.removeAll(keepingCapacity: false)
                    discardingOversizedFrame = true
                } else {
                    buffer.append(contentsOf: segment)
                }
                break
            }
        }
    }

    private func writeOversizedFrameFailure() throws {
        try output.write(
            contentsOf: protocolFailureFrame(
                for: BrokerSessionHostProtocolError.frameTooLarge(maximumBytes: maximumFrameSize)
            )
        )
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
