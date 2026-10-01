import Foundation
import Darwin
import MCP

// Log to stderr (stdout is used for MCP protocol)
func log(_ msg: String) {
    FileHandle.standardError.write(Data("[HoloscapeMCP] \(msg)\n".utf8))
}

if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--holoscape-process-group-shell" {
    if getpgrp() != getpid(), setsid() == -1 {
        FileHandle.standardError.write(Data("Failed to create process session: \(String(cString: strerror(errno)))\n".utf8))
        exit(126)
    }
    let shellPath = "/bin/zsh"
    let loginFlag = "-lc"
    shellPath.withCString { shellPathPointer in
        loginFlag.withCString { loginFlagPointer in
            CommandLine.arguments[2].withCString { commandPointer in
                var arguments: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: shellPathPointer),
                    UnsafeMutablePointer(mutating: loginFlagPointer),
                    UnsafeMutablePointer(mutating: commandPointer),
                    nil,
                ]
                arguments.withUnsafeMutableBufferPointer { buffer in
                    _ = execv(shellPathPointer, buffer.baseAddress!)
                }
            }
        }
    }
    FileHandle.standardError.write(Data("Failed to exec shell: \(String(cString: strerror(errno)))\n".utf8))
    exit(127)
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
