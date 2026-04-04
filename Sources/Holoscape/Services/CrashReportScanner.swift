import Foundation

struct CrashLog {
    let path: URL
    let content: String
    let creationDate: Date
}

class CrashReportScanner {
    private let diagnosticsDir: URL

    init() {
        self.diagnosticsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// Scan for Holoscape crash logs created since the given date.
    func scanForCrashes(since lastLaunch: Date) -> [CrashLog] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diagnosticsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { url -> CrashLog? in
            let name = url.lastPathComponent
            guard name.contains("Holoscape") else { return nil }
            guard name.hasSuffix(".ips") || name.hasSuffix(".crash") else { return nil }

            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let created = attrs[.creationDate] as? Date,
                  created > lastLaunch else {
                return nil
            }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }

            return CrashLog(path: url, content: content, creationDate: created)
        }
    }
}
