import Foundation

struct BugReportResponse: Codable {
    let success: Bool
    let message: String?
}

struct PendingReportRetrySummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        enum Stage: String, Equatable, Sendable {
            case enumerate
            case metadata
            case read
            case decode
            case submit
            case rejected
            case remove
        }

        let fileName: String?
        let stage: Stage
        let message: String
    }

    var discoveredCount = 0
    var retriedCount = 0
    var expiredCount = 0
    var failures: [Failure] = []

    var logMessage: String {
        let base = "Pending report retry: discovered=\(discoveredCount), retried=\(retriedCount), expired=\(expiredCount), failures=\(failures.count)"
        guard !failures.isEmpty else { return base }
        let details = failures.map { failure in
            let target = failure.fileName ?? "pending-reports directory"
            return "\(target) [\(failure.stage.rawValue)]: \(failure.message)"
        }.joined(separator: "; ")
        return "\(base). \(details)"
    }
}

final class BugReportService: Sendable {
    let silAPIEndpoint: URL
    private let pendingDir: URL
    private let session: URLSession
    private let directoryContents: @Sendable (URL) throws -> [URL]
    private let creationDate: @Sendable (URL) throws -> Date?
    private let dataReader: @Sendable (URL) throws -> Data
    private let fileRemover: @Sendable (URL) throws -> Void

    init(
        endpoint: URL = URL(string: "https://api.synthinsightlabs.com/reports")!,
        session: URLSession = .shared,
        pendingDirectory: URL? = nil,
        directoryContents: @escaping @Sendable (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        },
        creationDate: @escaping @Sendable (URL) throws -> Date? = {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.creationDate] as? Date
        },
        dataReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        fileRemover: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.silAPIEndpoint = endpoint
        self.session = session
        self.pendingDir = pendingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".holoscape/pending-reports")
        self.directoryContents = directoryContents
        self.creationDate = creationDate
        self.dataReader = dataReader
        self.fileRemover = fileRemover
    }

    func submitBugReport(_ report: BugReport) async throws -> BugReportResponse {
        try await submit(report, path: "bug")
    }

    func submitCrashReport(_ report: CrashReport) async throws -> BugReportResponse {
        try await submit(report, path: "crash")
    }

    private func submit<Report: Encodable & Sendable>(
        _ report: Report,
        path: String
    ) async throws -> BugReportResponse {
        let url = silAPIEndpoint.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(report)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BugReportServiceError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BugReportServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(BugReportResponse.self, from: data)
        } catch {
            throw BugReportServiceError.invalidResponse
        }
    }

    // MARK: - Pending Report Persistence

    func savePendingBugReport(_ report: BugReport) throws {
        try savePending(report, prefix: "bug")
    }

    func savePendingCrashReport(_ report: CrashReport) throws {
        try savePending(report, prefix: "crash")
    }

    private func savePending<T: Encodable>(_ report: T, prefix: String) throws {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let filename = "\(prefix)-\(UUID().uuidString).json"
        let fileURL = pendingDir.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: .atomic)
    }

    func retryPendingReports() async -> PendingReportRetrySummary {
        guard FileManager.default.fileExists(atPath: pendingDir.path) else { return PendingReportRetrySummary() }

        let files: [URL]
        do {
            files = try directoryContents(pendingDir).filter {
                $0.pathExtension == "json"
                    && ($0.lastPathComponent.hasPrefix("bug-") || $0.lastPathComponent.hasPrefix("crash-"))
            }
        } catch {
            return PendingReportRetrySummary(failures: [
                .init(fileName: nil, stage: .enumerate, message: error.localizedDescription)
            ])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        var summary = PendingReportRetrySummary(discoveredCount: files.count)

        for file in files {
            let created: Date?
            do {
                created = try creationDate(file)
            } catch {
                summary.failures.append(.init(
                    fileName: file.lastPathComponent,
                    stage: .metadata,
                    message: error.localizedDescription
                ))
                continue
            }

            if let created, created < thirtyDaysAgo {
                do {
                    try fileRemover(file)
                    summary.expiredCount += 1
                } catch {
                    summary.failures.append(.init(
                        fileName: file.lastPathComponent,
                        stage: .remove,
                        message: error.localizedDescription
                    ))
                }
                continue
            }

            let data: Data
            do {
                data = try dataReader(file)
            } catch {
                summary.failures.append(.init(
                    fileName: file.lastPathComponent,
                    stage: .read,
                    message: error.localizedDescription
                ))
                continue
            }

            do {
                let response: BugReportResponse
                if file.lastPathComponent.hasPrefix("bug-") {
                    response = try await submitBugReport(decoder.decode(BugReport.self, from: data))
                } else {
                    response = try await submitCrashReport(decoder.decode(CrashReport.self, from: data))
                }
                guard response.success else {
                    summary.failures.append(.init(
                        fileName: file.lastPathComponent,
                        stage: .rejected,
                        message: response.message ?? "Report server rejected the pending report"
                    ))
                    continue
                }
                do {
                    try fileRemover(file)
                    summary.retriedCount += 1
                } catch {
                    summary.failures.append(.init(
                        fileName: file.lastPathComponent,
                        stage: .remove,
                        message: error.localizedDescription
                    ))
                }
            } catch is DecodingError {
                summary.failures.append(.init(
                    fileName: file.lastPathComponent,
                    stage: .decode,
                    message: "Saved report is not valid report JSON"
                ))
            } catch {
                summary.failures.append(.init(
                    fileName: file.lastPathComponent,
                    stage: .submit,
                    message: error.localizedDescription
                ))
            }
        }
        return summary
    }
}

enum BugReportServiceError: Error, Equatable {
    case nonHTTPResponse
    case httpError(statusCode: Int)
    case invalidResponse
}

extension BugReportServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Report server returned a non-HTTP response"
        case let .httpError(statusCode):
            return "Report server returned HTTP status \(statusCode)"
        case .invalidResponse:
            return "Report server returned an invalid response"
        }
    }
}
