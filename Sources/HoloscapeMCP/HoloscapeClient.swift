import Foundation

/// HTTP client for communicating with Holoscape's embedded API server.
struct HoloscapeClient: Sendable {
    let baseURL: String
    private let session: URLSession

    init(port: UInt16 = 7865) {
        self.init(baseURL: "http://127.0.0.1:\(port)")
    }

    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func listChannels() async throws -> [[String: Any]] {
        let data = try await get("/channels")
        guard let channels = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HoloscapeError.invalidResponse
        }
        return channels
    }

    func createChannel(type: String, dir: String?, label: String?, cmd: String?) async throws -> [String: Any] {
        var body: [String: Any] = ["type": type]
        if let dir { body["dir"] = dir }
        if let label { body["label"] = label }
        if let cmd { body["cmd"] = cmd }
        let data = try await post("/channels", body: body)
        return try decodeObject(from: data)
    }

    func switchChannel(id: String) async throws -> [String: Any] {
        let data = try await post("/channels/\(id)/switch", body: nil)
        return try decodeObject(from: data)
    }

    func closeChannel(id: String) async throws -> [String: Any] {
        let data = try await delete("/channels/\(id)")
        return try decodeObject(from: data)
    }

    func sendInput(id: String, text: String) async throws -> [String: Any] {
        let data = try await post("/channels/\(id)/input", body: ["text": text])
        return try decodeObject(from: data)
    }

    func readOutput(id: String, lines: Int = 50) async throws -> [String: Any] {
        let data = try await get("/channels/\(id)/output?lines=\(lines)")
        return try decodeObject(from: data)
    }

    // MARK: - HTTP Methods

    private func get(_ path: String) async throws -> Data {
        try await perform(request(path: path, method: "GET"))
    }

    private func post(_ path: String, body: [String: Any]?) async throws -> Data {
        var request = try request(path: path, method: "POST")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    private func delete(_ path: String) async throws -> Data {
        try await perform(request(path: path, method: "DELETE"))
    }

    private static let localAPIRequestTimeout: TimeInterval = 5

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw HoloscapeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.localAPIRequestTimeout
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw HoloscapeError.connectionFailed
        }
        guard let response = response as? HTTPURLResponse else {
            throw HoloscapeError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HoloscapeError.httpError(
                statusCode: response.statusCode,
                message: responseErrorMessage(from: data)
            )
        }
        return data
    }

    private func responseErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessage = object["error"] as? String else {
            return nil
        }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private func decodeObject(from data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HoloscapeError.invalidResponse
        }
        return result
    }
}

enum HoloscapeError: Error, Equatable {
    case invalidResponse
    case connectionFailed
    case httpError(statusCode: Int, message: String?)
}

extension HoloscapeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Holoscape returned an invalid response"
        case .connectionFailed:
            return "Could not connect to Holoscape"
        case let .httpError(statusCode, message):
            if let message {
                return "Holoscape returned HTTP status \(statusCode): \(message)"
            }
            return "Holoscape returned HTTP status \(statusCode)"
        }
    }
}
