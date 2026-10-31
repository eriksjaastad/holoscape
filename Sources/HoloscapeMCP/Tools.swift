import Foundation
import MCP

/// Mirrors MCP `Value` for tool-call parameters while preserving every JSON
/// string verbatim. MCP 0.12.1 otherwise converts data-URL-looking strings to
/// binary values before a tool can interpret schema-defined string arguments.
enum ToolArgumentValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ToolArgumentValue])
    case object([String: ToolArgumentValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ToolArgumentValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ToolArgumentValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Tool argument value type not found"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var mcpValue: Value {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let value):
            return .array(value.map(\.mcpValue))
        case .object(let value):
            return .object(value.mapValues(\.mcpValue))
        }
    }
}

enum HoloscapeCallTool: MCP.Method {
    static let name = CallTool.name
    typealias Result = CallTool.Result

    struct Parameters: Hashable, Sendable, Codable {
        let _meta: Metadata?
        let name: String
        private let rawArguments: [String: ToolArgumentValue]?

        var arguments: [String: Value]? {
            rawArguments?.mapValues(\.mcpValue)
        }

        private enum CodingKeys: String, CodingKey {
            case _meta, name, arguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _meta = try container.decodeIfPresent(Metadata.self, forKey: ._meta)
            name = try container.decode(String.self, forKey: .name)
            rawArguments = try container.decodeIfPresent(
                [String: ToolArgumentValue].self,
                forKey: .arguments
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(rawArguments, forKey: .arguments)
        }
    }
}

func executeToolHandler(
    _ operation: () async throws -> CallTool.Result
) async throws -> CallTool.Result {
    do {
        return try await operation()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as FileSystemToolError {
        return CallTool.Result(
            content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
            isError: true
        )
    } catch let error as ProcessToolError {
        return CallTool.Result(
            content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
            isError: true
        )
    } catch let error as HoloscapeError {
        let outageAdvice = error == .connectionFailed ? ". Is Holoscape running?" : ""
        return CallTool.Result(
            content: [.text(text: "Error: \(error.localizedDescription)\(outageAdvice)", annotations: nil, _meta: nil)],
            isError: true
        )
    } catch {
        return CallTool.Result(
            content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

func openChannelTool(
    args: [String: Value],
    client: HoloscapeClient
) async throws -> CallTool.Result {
    guard let type = args["type"]?.stringValue,
          type == "shell" || type == "agent" else {
        return CallTool.Result(
            content: [.text(
                text: "Invalid 'type' parameter: expected 'shell' or 'agent'",
                annotations: nil,
                _meta: nil
            )],
            isError: true
        )
    }

    let dir = args["dir"]?.stringValue
    let label = args["label"]?.stringValue
    let cmd = args["cmd"]?.stringValue
    _ = try await client.createChannel(type: type, dir: dir, label: label, cmd: cmd)
    return CallTool.Result(
        content: [.text(
            text: "Created \(type) channel\(dir.map { " in \($0)" } ?? "")",
            annotations: nil,
            _meta: nil
        )]
    )
}

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
                        "type": .object([
                            "type": .string("string"),
                            "enum": .array([.string("shell"), .string("agent")]),
                            "description": .string("Channel type: 'shell' or 'agent'"),
                        ]),
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
            Tool(
                name: "holoscape_read_file",
                description: "Read a UTF-8 text file from the local filesystem.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("File path")]),
                        "maxBytes": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Maximum bytes to return; default 128000")]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            Tool(
                name: "holoscape_write_file",
                description: "Write UTF-8 text to a local file, creating parent directories as needed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("File path")]),
                        "content": .object(["type": .string("string"), "description": .string("File content")]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                ])
            ),
            Tool(
                name: "holoscape_list_directory",
                description: "List entries in a local directory.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Directory path")]),
                        "limit": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Maximum entries; default 200")]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            Tool(
                name: "holoscape_search_files",
                description: "Search file names by regular expression under a local directory.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Directory path")]),
                        "pattern": .object(["type": .string("string"), "description": .string("Regular expression matched against file names")]),
                        "limit": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Maximum matches; default 100")]),
                    ]),
                    "required": .array([.string("path"), .string("pattern")]),
                ])
            ),
            Tool(
                name: "holoscape_search_content",
                description: "Search UTF-8 file contents by regular expression under a local directory.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Directory path")]),
                        "pattern": .object(["type": .string("string"), "description": .string("Regular expression matched against text lines")]),
                        "limit": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Maximum line matches; default 100")]),
                    ]),
                    "required": .array([.string("path"), .string("pattern")]),
                ])
            ),
            Tool(
                name: "holoscape_run_process",
                description: "Run a local shell command via /bin/zsh -lc, capture stdout/stderr, honor workingDirectory/env/timeoutSeconds, and return exit status.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object(["type": .string("string"), "description": .string("Shell command to execute")]),
                        "workingDirectory": .object(["type": .string("string"), "description": .string("Optional working directory")]),
                        "env": .object(["type": .string("object"), "description": .string("Optional string environment variable overrides")]),
                        "timeoutSeconds": .object(["type": .string("number"), "exclusiveMinimum": .int(0), "description": .string("Timeout in seconds; default 30")]),
                    ]),
                    "required": .array([.string("command")]),
                ])
            ),
            Tool(
                name: "holoscape_run_applescript",
                description: "Execute AppleScript source locally through osascript with a timeout and return its result. This can control scriptable macOS apps and may trigger normal macOS Automation permission prompts.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object(["type": .string("string"), "description": .string("AppleScript source to execute")]),
                        "timeoutSeconds": .object(["type": .string("number"), "exclusiveMinimum": .int(0), "description": .string("Timeout in seconds; default 30")]),
                    ]),
                    "required": .array([.string("source")]),
                ])
            ),
        ])
    }

    await server.withMethodHandler(HoloscapeCallTool.self) { params in
        let args = params.arguments ?? [:]

        return try await executeToolHandler {
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
                return try await openChannelTool(args: args, client: client)

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

            case "holoscape_read_file":
                return CallTool.Result(content: [.text(text: try readFileTool(args: args), annotations: nil, _meta: nil)])

            case "holoscape_write_file":
                return CallTool.Result(content: [.text(text: try writeFileTool(args: args), annotations: nil, _meta: nil)])

            case "holoscape_list_directory":
                return CallTool.Result(content: [.text(text: try listDirectoryTool(args: args), annotations: nil, _meta: nil)])

            case "holoscape_search_files":
                return CallTool.Result(content: [.text(text: try searchFilesTool(args: args), annotations: nil, _meta: nil)])

            case "holoscape_search_content":
                return CallTool.Result(content: [.text(text: try searchContentTool(args: args), annotations: nil, _meta: nil)])

            case "holoscape_run_process":
                let request = try processToolRequest(from: args)
                let result = try await runProcessTool(request)
                return CallTool.Result(
                    content: [.text(text: formatProcessToolResult(result), annotations: nil, _meta: nil)],
                    isError: processToolResultIsError(result)
                )

            case "holoscape_run_applescript":
                do {
                    let result = try await runAppleScriptTool(args: args)
                    return CallTool.Result(
                        content: [.text(text: formatAppleScriptToolResult(result), annotations: nil, _meta: nil)]
                    )
                } catch {
                    return CallTool.Result(content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
                }

            default:
                return CallTool.Result(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        }
    }
}
