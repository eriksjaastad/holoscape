import Foundation

struct BugReportResponse: Codable {
    let success: Bool
    let message: String?
}

final class BugReportService: Sendable {
    let silAPIEndpoint: URL
    private let pendingDir: URL

    init(endpoint: URL = URL(string: "https://api.synthinsightlabs.com/reports")!) {
        self.silAPIEndpoint = endpoint
        self.pendingDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".holoscape/pending-reports")
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

    // MARK: - Pending Report Persistence

    func savePendingBugReport(_ report: BugReport) {
        savePending(report, prefix: "bug")
    }

    func savePendingCrashReport(_ report: CrashReport) {
        savePending(report, prefix: "crash")
    }

    private func savePending<T: Encodable>(_ report: T, prefix: String) {
        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let filename = "\(prefix)-\(UUID().uuidString).json"
        let fileURL = pendingDir.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func retryPendingReports() {
        guard FileManager.default.fileExists(atPath: pendingDir.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)

        for file in files where file.pathExtension == "json" {
            // Delete pending reports older than 30 days
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < thirtyDaysAgo {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            guard let data = try? Data(contentsOf: file) else { continue }

            if file.lastPathComponent.hasPrefix("bug-") {
                guard let report = try? decoder.decode(BugReport.self, from: data) else { continue }
                Task {
                    do {
                        let response = try await self.submitBugReport(report)
                        if response.success {
                            try? FileManager.default.removeItem(at: file)
                        }
                    } catch {
                        print("[BugReportService] Retry failed for \(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } else if file.lastPathComponent.hasPrefix("crash-") {
                guard let report = try? decoder.decode(CrashReport.self, from: data) else { continue }
                Task {
                    do {
                        let response = try await self.submitCrashReport(report)
                        if response.success {
                            try? FileManager.default.removeItem(at: file)
                        }
                    } catch {
                        print("[BugReportService] Retry failed for \(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
