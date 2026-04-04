import Foundation

struct BugReportResponse: Codable {
    let success: Bool
    let message: String?
}

final class BugReportService: Sendable {
    let silAPIEndpoint: URL

    init(endpoint: URL = URL(string: "https://api.synthinsightlabs.com/reports")!) {
        self.silAPIEndpoint = endpoint
    }

    func submitBugReport(_ report: BugReport) async throws -> BugReportResponse {
        let url = silAPIEndpoint.appendingPathComponent("bug")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(report)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(BugReportResponse.self, from: data)
    }

    func submitCrashReport(_ report: CrashReport) async throws -> BugReportResponse {
        let url = silAPIEndpoint.appendingPathComponent("crash")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(report)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(BugReportResponse.self, from: data)
    }
}
