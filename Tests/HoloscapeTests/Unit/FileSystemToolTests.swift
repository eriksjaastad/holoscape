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
}
