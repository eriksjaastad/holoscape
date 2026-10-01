import Foundation
import Darwin
import MCP

// Log to stderr (stdout is used for MCP protocol)
func log(_ msg: String) {
    FileHandle.standardError.write(Data("[HoloscapeMCP] \(msg)\n".utf8))
}

if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--holoscape-process-shell-runner" {
    runProcessToolShellRunner(command: CommandLine.arguments[2])
}

if CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--holoscape-process-controller",
   let timeoutSeconds = Double(CommandLine.arguments[3]) {
    runProcessToolController(
        command: CommandLine.arguments[2],
        timeoutSeconds: timeoutSeconds,
        statusPath: CommandLine.arguments[4]
    )
}

log("Starting server...")

let server = Server(
    name: "holoscape",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

let client = HoloscapeClient()
await registerTools(on: server, client: client)
log("Tools registered")

let transport = StdioTransport()
log("Transport created, starting...")
try await server.start(transport: transport)
log("Server started, waiting for messages...")

// Keep the process alive while the server handles messages
while true {
    try await Task.sleep(for: .seconds(3600))
}
