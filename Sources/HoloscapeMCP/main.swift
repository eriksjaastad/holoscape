import Foundation
import MCP

// Log to stderr (stdout is used for MCP protocol)
func log(_ msg: String) {
    FileHandle.standardError.write(Data("[HoloscapeMCP] \(msg)\n".utf8))
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
