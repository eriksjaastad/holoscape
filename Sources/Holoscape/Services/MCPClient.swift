import Foundation

actor MCPClient {
    private let endpoint: URL
    private let session: URLSession
    private var requestId: Int = 0
    private var initialized: Bool = false

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Perform MCP initialize handshake.
    func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Holoscape", "version": "2.0"],
        ]
        let _: [String: Any] = try await sendRequest(method: "initialize", params: params)
        try await sendNotification(method: "notifications/initialized", params: [:])
        initialized = true
    }

    /// Send a message to the MCP server via tools/call.
    func sendMessage(_ text: String) async throws -> String {
        guard initialized else { throw MCPError.notInitialized }
        let params: [String: Any] = [
            "name": "send_message",
            "arguments": ["message": text],
        ]
        let result: [String: Any] = try await sendRequest(method: "tools/call", params: params)
        if let content = result["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text
        }
        throw MCPError.invalidResponse
    }

    var isInitialized: Bool { initialized }

    // MARK: - Private

    private func sendRequest<T>(method: String, params: [String: Any]) async throws -> T {
        requestId += 1
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPError.invalidResponse
        }
        if let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           let message = error["message"] as? String {
            throw MCPError.protocolError(code: code, message: message)
        }
        guard let result = json["result"] as? T else {
            throw MCPError.invalidResponse
        }
        return result
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw MCPError.connectionFailed(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
    }

    enum MCPError: Error, LocalizedError {
        case notInitialized
        case connectionFailed(statusCode: Int?)
        case invalidResponse
        case protocolError(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "MCP client not initialized"
            case let .connectionFailed(statusCode?):
                return "MCP connection failed with HTTP status \(statusCode)"
            case .connectionFailed(statusCode: nil):
                return "MCP connection failed"
            case .invalidResponse:
                return "Invalid MCP response"
            case let .protocolError(code, message):
                return "MCP protocol error \(code): \(message)"
            }
        }
    }
}
