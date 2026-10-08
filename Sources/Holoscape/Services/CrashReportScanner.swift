import Foundation

struct CrashLog {
    let path: URL
    let content: String
    let creationDate: Date
}

struct CrashReportScanFailure: Equatable {
    enum Operation: String, Equatable {
        case enumerateDirectory
        case readMetadata
        case readContent
    }

    let operation: Operation
    let path: String
    let message: String
}

struct CrashReportScanResult {
    let logs: [CrashLog]
    let failures: [CrashReportScanFailure]
}

final class CrashReportScanner {
    typealias DirectoryReader = (URL) throws -> [URL]
    typealias MetadataReader = (String) throws -> [FileAttributeKey: Any]
    typealias ContentReader = (URL) throws -> String

    private let diagnosticsDir: URL
    private let contentsOfDirectory: DirectoryReader
    private let attributesOfItem: MetadataReader
    private let readContents: ContentReader

    convenience init() {
        self.init(
            diagnosticsDir: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports"),
            contentsOfDirectory: { directory in
                try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: [.skipsHiddenFiles]
                )
            },
            attributesOfItem: FileManager.default.attributesOfItem(atPath:),
            readContents: { try String(contentsOf: $0, encoding: .utf8) }
        )
    }

    init(
        diagnosticsDir: URL,
        contentsOfDirectory: @escaping DirectoryReader,
        attributesOfItem: @escaping MetadataReader,
        readContents: @escaping ContentReader
    ) {
        self.diagnosticsDir = diagnosticsDir
        self.contentsOfDirectory = contentsOfDirectory
        self.attributesOfItem = attributesOfItem
        self.readContents = readContents
    }

    /// Scan for Holoscape crash logs created since the given date. Failures are
    /// returned alongside readable logs so startup can remain best-effort
    /// without misreporting an unreadable crash source as an empty one.
    func scanForCrashes(since lastLaunch: Date) -> CrashReportScanResult {
        let files: [URL]
        do {
            files = try contentsOfDirectory(diagnosticsDir)
        } catch {
            return CrashReportScanResult(
                logs: [],
                failures: [failure(.enumerateDirectory, path: diagnosticsDir, error: error)]
            )
        }

        var logs: [CrashLog] = []
        var failures: [CrashReportScanFailure] = []
        for url in files {
            let name = url.lastPathComponent
            guard name.contains("Holoscape"),
                  name.hasSuffix(".ips") || name.hasSuffix(".crash") else {
                continue
            }

            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try attributesOfItem(url.path)
            } catch {
                failures.append(failure(.readMetadata, path: url, error: error))
                continue
            }
            guard let created = attributes[.creationDate] as? Date else {
                failures.append(CrashReportScanFailure(
                    operation: .readMetadata,
                    path: url.path,
                    message: "missing creation date"
                ))
                continue
            }
            guard created > lastLaunch else { continue }

            do {
                logs.append(CrashLog(
                    path: url,
                    content: try readContents(url),
                    creationDate: created
                ))
            } catch {
                failures.append(failure(.readContent, path: url, error: error))
            }
        }

        return CrashReportScanResult(logs: logs, failures: failures)
    }

    private func failure(
        _ operation: CrashReportScanFailure.Operation,
        path: URL,
        error: Error
    ) -> CrashReportScanFailure {
        CrashReportScanFailure(
            operation: operation,
            path: path.path,
            message: error.localizedDescription
        )
    }
}
