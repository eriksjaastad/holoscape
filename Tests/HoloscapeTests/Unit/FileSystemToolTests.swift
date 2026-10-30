import Darwin
import Foundation
import MCP
import XCTest
@testable import HoloscapeMCP

final class FileSystemToolTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-filesystem-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            _ = chmod(temporaryDirectory.path, mode_t(0o700))
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testToolHandlerReportsFilesystemFailureWithoutHoloscapeOutageAdvice() async throws {
        let result = try await executeToolHandler {
            throw FileSystemToolError.enumerationFailed(
                path: "/tmp/blocked",
                message: "permission denied"
            )
        }

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.content.count, 1)
        guard case let .text(text, _, _) = result.content[0] else {
            return XCTFail("Expected text error content")
        }
        XCTAssertEqual(text, "Error: Could not enumerate directory at /tmp/blocked: permission denied")
        XCTAssertFalse(text.contains("Is Holoscape running?"))
    }

    func testReadFileRejectsNegativeMaxBytesBeforeFilesystemAccess() {
        XCTAssertThrowsError(try readFileTool(args: [
            "path": .string("/missing"),
            "maxBytes": .int(-1),
        ])) { error in
            guard case .invalidMaxBytes(-1) = error as? FileSystemToolError else {
                return XCTFail("Expected invalidMaxBytes, got \(error)")
            }
        }
    }

    func testReadFileAllowsZeroMaxBytes() throws {
        let file = temporaryDirectory.appendingPathComponent("content.txt")
        try Data("content".utf8).write(to: file)

        XCTAssertEqual(try readFileTool(args: [
            "path": .string(file.path),
            "maxBytes": .int(0),
        ]), "\n… truncated at 0 of 7 bytes")
    }

    func testListDirectoryRejectsNegativeLimitBeforeFilesystemAccess() {
        assertNegativeLimitRejected {
            try listDirectoryTool(args: ["path": .string("/missing"), "limit": .int(-1)])
        }
    }

    func testSearchFilesRejectsNegativeLimitBeforeFilesystemAccess() {
        assertNegativeLimitRejected {
            try searchFilesTool(args: [
                "path": .string("/missing"),
                "pattern": .string("anything"),
                "limit": .int(-1),
            ])
        }
    }

    func testSearchContentRejectsNegativeLimitBeforeFilesystemAccess() {
        assertNegativeLimitRejected {
            try searchContentTool(args: [
                "path": .string("/missing"),
                "pattern": .string("anything"),
                "limit": .int(-1),
            ])
        }
    }

    func testZeroSearchLimitsReturnNoResults() throws {
        try Data("needle\n".utf8).write(to: temporaryDirectory.appendingPathComponent("needle.txt"))

        XCTAssertEqual(try searchFilesTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("needle"),
            "limit": .int(0),
        ]), "(no matching files)")
        XCTAssertEqual(try searchContentTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("needle"),
            "limit": .int(0),
        ]), "(no content matches)")
    }

    func testSearchContentSkipsValidNonUTF8Files() throws {
        try Data([0xFF, 0xFE, 0xFD]).write(to: temporaryDirectory.appendingPathComponent("binary.dat"))
        try Data("needle\n".utf8).write(to: temporaryDirectory.appendingPathComponent("text.txt"))

        let result = try searchContentTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("needle"),
        ])

        XCTAssertTrue(result.contains("text.txt:1:needle"))
        XCTAssertFalse(result.contains("binary.dat"))
    }

    func testSearchContentSurfacesUnreadableFileInsteadOfReturningNoMatches() throws {
        let unreadable = temporaryDirectory.appendingPathComponent("unreadable.txt")
        try Data("needle\n".utf8).write(to: unreadable)
        XCTAssertEqual(chmod(unreadable.path, mode_t(0o000)), 0)
        defer { _ = chmod(unreadable.path, mode_t(0o600)) }

        XCTAssertThrowsError(try searchContentTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("needle"),
        ])) { error in
            guard case let .fileReadFailed(path, _) = error as? FileSystemToolError else {
                return XCTFail("Expected fileReadFailed, got \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, unreadable.lastPathComponent)
            XCTAssertTrue(path.contains(temporaryDirectory.lastPathComponent))
        }
    }

    func testSearchFilesSurfacesDirectoryEnumerationFailure() throws {
        let unreadableDirectory = temporaryDirectory.appendingPathComponent("unreadable-files", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try Data().write(to: unreadableDirectory.appendingPathComponent("hidden.txt"))
        XCTAssertEqual(chmod(unreadableDirectory.path, mode_t(0o000)), 0)
        defer { _ = chmod(unreadableDirectory.path, mode_t(0o700)) }

        XCTAssertThrowsError(try searchFilesTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("hidden"),
        ])) { error in
            guard case let .enumerationFailed(path, _) = error as? FileSystemToolError else {
                return XCTFail("Expected enumerationFailed, got \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, unreadableDirectory.lastPathComponent)
            XCTAssertTrue(path.contains(temporaryDirectory.lastPathComponent))
        }
    }

    func testSearchContentSurfacesDirectoryEnumerationFailure() throws {
        let unreadableDirectory = temporaryDirectory.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try Data("needle\n".utf8).write(to: unreadableDirectory.appendingPathComponent("hidden.txt"))
        XCTAssertEqual(chmod(unreadableDirectory.path, mode_t(0o000)), 0)
        defer { _ = chmod(unreadableDirectory.path, mode_t(0o700)) }

        XCTAssertThrowsError(try searchContentTool(args: [
            "path": .string(temporaryDirectory.path),
            "pattern": .string("needle"),
        ])) { error in
            guard case let .enumerationFailed(path, _) = error as? FileSystemToolError else {
                return XCTFail("Expected enumerationFailed, got \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, unreadableDirectory.lastPathComponent)
            XCTAssertTrue(path.contains(temporaryDirectory.lastPathComponent))
        }
    }

    private func assertNegativeLimitRejected(
        operation: () throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case .invalidLimit = error as? FileSystemToolError else {
                return XCTFail("Expected invalidLimit, got \(error)", file: file, line: line)
            }
        }
    }
}
