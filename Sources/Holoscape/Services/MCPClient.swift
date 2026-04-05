import Foundation

actor MCPClient {
    private let endpoint: URL
    private var requestId: Int = 0
    private var initialized: Bool = false

    init(endpoint: URL) {
        self.endpoint = endpoint
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

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MCPError.connectionFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = json["result"] as? T else {
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
        let _ = try await URLSession.shared.data(for: request)
    }

    enum MCPError: Error, LocalizedError {
        case notInitialized
        case connectionFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "MCP client not initialized"
            case .connectionFailed: return "MCP connection failed"
            case .invalidResponse: return "Invalid MCP response"
            }
        }
    }
}
