import Foundation

/// CLI entry point for running Holoscape as its own broker host process.
///
/// The app process checks this before constructing `NSApplication`. That keeps the
/// broker boundary explicit: callers must launch the Holoscape executable with
/// `--broker-host`, and any malformed invocation fails loudly instead of falling
/// through to the GUI or silently using an in-process fallback.
struct BrokerSessionHostCommand {
    enum CommandError: Error, Equatable {
        case unexpectedArguments([String])
        case missingSocketPath
        case emptySocketPath
    }

    static let modeFlag = "--broker-host"
    static let socketModeFlag = "--broker-host-socket"

    private let arguments: [String]
    private let input: FileHandle
    private let output: FileHandle
    private let runtimeFactory: () -> any BrokerSessionRuntime
    private let socketMaxConnections: Int?

    init(
        arguments: [String],
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        runtimeFactory: @escaping () -> any BrokerSessionRuntime = { NativePTYBrokerSessionRuntime() },
        socketMaxConnections: Int? = nil
    ) {
        self.arguments = arguments
        self.input = input
        self.output = output
        self.runtimeFactory = runtimeFactory
        self.socketMaxConnections = socketMaxConnections
    }

    func runIfRequested() throws -> Bool {
        guard arguments.contains(Self.modeFlag) || arguments.contains(Self.socketModeFlag) else {
            return false
        }

        let trailingArguments = Array(arguments.dropFirst())
        if trailingArguments.contains(Self.modeFlag) {
            let unexpectedArguments = trailingArguments.filter { $0 != Self.modeFlag }
            guard unexpectedArguments.isEmpty else {
                throw CommandError.unexpectedArguments(Array(unexpectedArguments))
            }

            let server = BrokerSessionHostStdioServer(
                host: BrokerSessionHost(runtime: runtimeFactory()),
                input: input,
                output: output
            )
            try server.runUntilEOF()
            return true
        }

        guard let flagIndex = trailingArguments.firstIndex(of: Self.socketModeFlag) else {
            return false
        }
        let unexpectedArguments: [String] = trailingArguments.enumerated().compactMap { index, argument in
            if index == flagIndex || index == flagIndex + 1 { return nil as String? }
            return argument
        }
        guard unexpectedArguments.isEmpty else {
            throw CommandError.unexpectedArguments(unexpectedArguments)
        }
        let socketPathIndex = flagIndex + 1
        guard trailingArguments.indices.contains(socketPathIndex) else {
            throw CommandError.missingSocketPath
        }
        let socketPath = trailingArguments[socketPathIndex]
        guard !socketPath.isEmpty else {
            throw CommandError.emptySocketPath
        }

        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtimeFactory()),
        )
        try server.run(maxConnections: socketMaxConnections)
        return true
    }
}
