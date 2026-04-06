import Foundation

/// HTTP client for communicating with Holoscape's embedded API server.
struct HoloscapeClient: Sendable {
    let baseURL: String

    init(port: UInt16 = 7865) {
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    func listChannels() async throws -> [[String: Any]] {
        let data = try await get("/channels")
        guard let channels = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
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
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func switchChannel(id: String) async throws -> [String: Any] {
        let data = try await post("/channels/\(id)/switch", body: nil)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func closeChannel(id: String) async throws -> [String: Any] {
        let data = try await delete("/channels/\(id)")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func sendInput(id: String, text: String) async throws -> [String: Any] {
        let data = try await post("/channels/\(id)/input", body: ["text": text])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func readOutput(id: String, lines: Int = 50) async throws -> [String: Any] {
        let data = try await get("/channels/\(id)/output?lines=\(lines)")
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HoloscapeError.invalidResponse
        }
        return result
    }

    // MARK: - HTTP Methods

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: baseURL + path)!
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private func post(_ path: String, body: [String: Any]?) async throws -> Data {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func delete(_ path: String) async throws -> Data {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}

enum HoloscapeError: Error {
    case invalidResponse
    case connectionFailed
}
