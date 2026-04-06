import Foundation
import MCP

func registerTools(on server: Server, client: HoloscapeClient) async {
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [
            Tool(
                name: "holoscape_list_channels",
                description: "List all open channels/tabs in Holoscape with their IDs, labels, types, and states",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "holoscape_open_channel",
                description: "Open a new shell or agent tab in Holoscape. Use type=shell for shells. Specify dir for working directory and cmd to auto-run a command (e.g. cmd=claude to start a Claude session).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string"), "description": .string("Channel type: 'shell' or 'agent'")]),
                        "dir": .object(["type": .string("string"), "description": .string("Working directory path")]),
                        "label": .object(["type": .string("string"), "description": .string("Custom tab label")]),
                        "cmd": .object(["type": .string("string"), "description": .string("Command to run after opening (e.g. 'claude')")]),
                    ]),
                    "required": .array([.string("type")]),
                ])
            ),
            Tool(
                name: "holoscape_switch_channel",
                description: "Switch the active/visible channel in Holoscape. Accepts a channel ID (UUID) or display label.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "channel": .object(["type": .string("string"), "description": .string("Channel UUID or display label")]),
                    ]),
                    "required": .array([.string("channel")]),
                ])
            ),
            Tool(
                name: "holoscape_close_channel",
                description: "Close a channel/tab in Holoscape. Accepts a channel ID (UUID) or display label.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "channel": .object(["type": .string("string"), "description": .string("Channel UUID or display label")]),
                    ]),
                    "required": .array([.string("channel")]),
                ])
            ),
            Tool(
                name: "holoscape_send_input",
                description: "Send text input to a channel in Holoscape. The text is sent as if typed into the terminal.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "channel": .object(["type": .string("string"), "description": .string("Channel UUID or display label")]),
                        "text": .object(["type": .string("string"), "description": .string("Text to send to the channel")]),
                    ]),
                    "required": .array([.string("channel"), .string("text")]),
                ])
            ),
            Tool(
                name: "holoscape_read_output",
                description: "Read the last N lines of output from a channel in Holoscape.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "channel": .object(["type": .string("string"), "description": .string("Channel UUID or display label")]),
                        "lines": .object(["type": .string("integer"), "description": .string("Number of lines to read (default 50)")]),
                    ]),
                    "required": .array([.string("channel")]),
                ])
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        let args = params.arguments ?? [:]

        do {
            switch params.name {
            case "holoscape_list_channels":
                let channels = try await client.listChannels()
                let text = channels.map { ch -> String in
                    let label = ch["label"] as? String ?? "unknown"
                    let type = ch["type"] as? String ?? "unknown"
                    let state = ch["state"] as? String ?? "unknown"
                    let id = ch["id"] as? String ?? ""
                    return "[\(state)] \(label) (\(type)) — \(id)"
                }.joined(separator: "\n")
                return CallTool.Result(content: [.text(text: text.isEmpty ? "No channels open" : text, annotations: nil, _meta: nil)])

            case "holoscape_open_channel":
                let type = args["type"]?.stringValue ?? "shell"
                let dir = args["dir"]?.stringValue
                let label = args["label"]?.stringValue
                let cmd = args["cmd"]?.stringValue
                _ = try await client.createChannel(type: type, dir: dir, label: label, cmd: cmd)
                return CallTool.Result(content: [.text(text: "Created \(type) channel\(dir.map { " in \($0)" } ?? "")", annotations: nil, _meta: nil)])

            case "holoscape_switch_channel":
                guard let channel = args["channel"]?.stringValue else {
                    return CallTool.Result(content: [.text(text: "Missing 'channel' parameter", annotations: nil, _meta: nil)], isError: true)
                }
                let result = try await client.switchChannel(id: channel)
                let label = result["label"] as? String ?? channel
                return CallTool.Result(content: [.text(text: "Switched to \(label)", annotations: nil, _meta: nil)])

            case "holoscape_close_channel":
                guard let channel = args["channel"]?.stringValue else {
                    return CallTool.Result(content: [.text(text: "Missing 'channel' parameter", annotations: nil, _meta: nil)], isError: true)
                }
                _ = try await client.closeChannel(id: channel)
                return CallTool.Result(content: [.text(text: "Closed channel \(channel)", annotations: nil, _meta: nil)])

            case "holoscape_send_input":
                guard let channel = args["channel"]?.stringValue,
                      let text = args["text"]?.stringValue else {
                    return CallTool.Result(content: [.text(text: "Missing 'channel' or 'text' parameter", annotations: nil, _meta: nil)], isError: true)
                }
                _ = try await client.sendInput(id: channel, text: text)
                return CallTool.Result(content: [.text(text: "Sent input to \(channel)", annotations: nil, _meta: nil)])

            case "holoscape_read_output":
                guard let channel = args["channel"]?.stringValue else {
                    return CallTool.Result(content: [.text(text: "Missing 'channel' parameter", annotations: nil, _meta: nil)], isError: true)
                }
                let lines = args["lines"]?.intValue ?? 50
                let result = try await client.readOutput(id: channel, lines: lines)
                let output = (result["lines"] as? [String])?.joined(separator: "\n") ?? ""
                return CallTool.Result(content: [.text(text: output.isEmpty ? "(no output)" : output, annotations: nil, _meta: nil)])

            default:
                return CallTool.Result(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error.localizedDescription). Is Holoscape running?", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
