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
    }

    static let modeFlag = "--broker-host"

    private let arguments: [String]
    private let input: FileHandle
    private let output: FileHandle
    private let runtimeFactory: () -> any BrokerSessionRuntime

    init(
        arguments: [String],
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        runtimeFactory: @escaping () -> any BrokerSessionRuntime = { NativePTYBrokerSessionRuntime() }
    ) {
        self.arguments = arguments
        self.input = input
        self.output = output
        self.runtimeFactory = runtimeFactory
    }

    func runIfRequested() throws -> Bool {
        guard arguments.contains(Self.modeFlag) else {
            return false
        }

        let trailingArguments = arguments.dropFirst()
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
}
