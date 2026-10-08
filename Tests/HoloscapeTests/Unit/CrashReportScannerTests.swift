import XCTest
@testable import Holoscape

final class CrashReportScannerTests: XCTestCase {
    private enum TestFailure: Error {
        case denied
    }

    func testDirectoryEnumerationFailureIsDistinguishedFromEmptyScan() {
        let diagnosticsDirectory = URL(fileURLWithPath: "/diagnostics")
        let scanner = CrashReportScanner(
            diagnosticsDir: diagnosticsDirectory,
            contentsOfDirectory: { _ in throw TestFailure.denied },
            attributesOfItem: { _ in [:] },
            readContents: { _ in "" }
        )

        let result = scanner.scanForCrashes(since: .distantPast)

        XCTAssertTrue(result.logs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.operation, .enumerateDirectory)
        XCTAssertEqual(result.failures.first?.path, diagnosticsDirectory.path)
    }

    func testMatchingFileFailuresRemainObservableWhileReadableCrashesAreReturned() {
        let diagnosticsDirectory = URL(fileURLWithPath: "/diagnostics")
        let metadataFailure = diagnosticsDirectory.appendingPathComponent("Holoscape-metadata.ips")
        let contentFailure = diagnosticsDirectory.appendingPathComponent("Holoscape-content.crash")
        let readable = diagnosticsDirectory.appendingPathComponent("Holoscape-readable.ips")
        let created = Date(timeIntervalSince1970: 100)
        let scanner = CrashReportScanner(
            diagnosticsDir: diagnosticsDirectory,
            contentsOfDirectory: { _ in [metadataFailure, contentFailure, readable] },
            attributesOfItem: { path in
                if path == metadataFailure.path { throw TestFailure.denied }
                return [.creationDate: created]
            },
            readContents: { url in
                if url == contentFailure { throw TestFailure.denied }
                return "readable crash"
            }
        )

        let result = scanner.scanForCrashes(since: Date(timeIntervalSince1970: 50))

        XCTAssertEqual(result.logs.map(\.path), [readable])
        XCTAssertEqual(result.logs.first?.content, "readable crash")
        XCTAssertEqual(result.failures.map(\.operation), [.readMetadata, .readContent])
        XCTAssertEqual(result.failures.map(\.path), [metadataFailure.path, contentFailure.path])
    }

    func testNonMatchingAndOldFilesDoNotProduceFailures() {
        let diagnosticsDirectory = URL(fileURLWithPath: "/diagnostics")
        let unrelated = diagnosticsDirectory.appendingPathComponent("OtherApp.ips")
        let old = diagnosticsDirectory.appendingPathComponent("Holoscape-old.ips")
        let scanner = CrashReportScanner(
            diagnosticsDir: diagnosticsDirectory,
            contentsOfDirectory: { _ in [unrelated, old] },
            attributesOfItem: { _ in [.creationDate: Date(timeIntervalSince1970: 10)] },
            readContents: { _ in "old crash" }
        )

        let result = scanner.scanForCrashes(since: Date(timeIntervalSince1970: 20))

        XCTAssertTrue(result.logs.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testAppDelegateReportsEveryCrashScanFailure() {
        let failures = [
            CrashReportScanFailure(
                operation: .enumerateDirectory,
                path: "/diagnostics",
                message: "denied"
            ),
            CrashReportScanFailure(
                operation: .readContent,
                path: "/diagnostics/Holoscape.ips",
                message: "unreadable"
            ),
        ]
        var messages: [String] = []

        AppDelegate.reportCrashScanFailures(failures) { messages.append($0) }

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].contains("enumerateDirectory"))
        XCTAssertTrue(messages[0].contains("/diagnostics"))
        XCTAssertTrue(messages[1].contains("readContent"))
        XCTAssertTrue(messages[1].contains("Holoscape.ips"))
    }
}
