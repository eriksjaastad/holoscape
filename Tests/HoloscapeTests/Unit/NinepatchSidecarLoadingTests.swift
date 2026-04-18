import XCTest
@testable import Holoscape

/// Task 8.2 — `SkinEngine.loadNinepatchSidecar(for:in:)`:
///   - Returns nil when no sidecar sits next to the image
///   - Decodes and returns a valid sidecar from `<image>.ninepatch.json`
///   - Drops sidecars with malformed JSON or invalid stretch ranges
///   - Propagates `.invalidPath` when the image path itself is unsafe
@MainActor
final class NinepatchSidecarLoadingTests: XCTestCase {

    private var skinDir: URL!
    private let engine = SkinEngine()

    override func setUpWithError() throws {
        try super.setUpWithError()
        skinDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-9p-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: skinDir)
        try super.tearDownWithError()
    }

    // MARK: - Happy path

    func testLoadsValidSidecar() throws {
        let imagePath = "assets/tab-bg.png"
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: #"{"stretchX":[16,48],"stretchY":[8,24]}"#
        )

        let sidecar = try engine.loadNinepatchSidecar(for: imagePath, in: skinDir)
        XCTAssertEqual(sidecar?.stretchX, [16, 48])
        XCTAssertEqual(sidecar?.stretchY, [8, 24])
    }

    func testReturnsNilWhenNoSidecarFile() throws {
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar,
                     "Missing sidecar is the common case — must return nil, not throw")
    }

    // MARK: - Malformed inputs

    func testDropsMalformedJSON() throws {
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: "{ not valid json"
        )
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar, "Malformed JSON must be logged and dropped, not thrown")
    }

    func testDropsSidecarWithDegenerateRanges() throws {
        // stretchX[0] == stretchX[1] → zero-width band → invalid
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: #"{"stretchX":[16,16],"stretchY":[8,24]}"#
        )
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar,
                     "Degenerate ranges must be dropped so caller falls back to stretch mode")
    }

    func testDropsSidecarWithReversedRanges() throws {
        // stretchX[0] > stretchX[1] → isValid false
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: #"{"stretchX":[48,16],"stretchY":[8,24]}"#
        )
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar, "Reversed ranges fail isValid and must drop to stretch fallback")
    }

    func testDropsSidecarWithNegativeStart() throws {
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: #"{"stretchX":[-1,16],"stretchY":[8,24]}"#
        )
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar, "Negative start fails isValid and must drop to stretch fallback")
    }

    func testDropsSidecarWithWrongElementCount() throws {
        // One-element stretchX array → isValid fails the count guard,
        // a distinct branch from the range-validity branches.
        try writeSidecar(
            relPath: "assets/tab-bg.ninepatch.json",
            body: #"{"stretchX":[16],"stretchY":[8,24]}"#
        )
        let sidecar = try engine.loadNinepatchSidecar(for: "assets/tab-bg.png", in: skinDir)
        XCTAssertNil(sidecar, "Wrong-count stretch arrays fail isValid and must drop")
    }

    // MARK: - Path validation

    func testRejectsUnsafeImagePath() {
        XCTAssertThrowsError(try engine.loadNinepatchSidecar(
            for: "../../etc/passwd.png", in: skinDir)
        ) { err in
            XCTAssertEqual(err as? SkinAssetError, .invalidPath("../../etc/passwd.png"),
                           "Path validation runs before any filesystem access")
        }
    }

    func testRejectsSidecarSymlinkEscapingSkinDir() throws {
        // Place the real sidecar outside the skin directory, then plant a
        // symlink inside the skin dir at the expected sidecar location.
        // The string-level gate passes (the image path is safe); the
        // filesystem-level gate must catch the sidecar's symlink escape.
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-9p-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let realSidecar = outsideDir.appendingPathComponent("secret.ninepatch.json")
        try Data(#"{"stretchX":[0,1],"stretchY":[0,1]}"#.utf8).write(to: realSidecar)

        let linkRelPath = "assets/tab-bg.ninepatch.json"
        let link = skinDir.appendingPathComponent(linkRelPath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realSidecar)

        XCTAssertThrowsError(try engine.loadNinepatchSidecar(
            for: "assets/tab-bg.png", in: skinDir)
        ) { err in
            // The error must name the sidecar (actual offender), not the
            // image path that implied it.
            XCTAssertEqual(err as? SkinAssetError, .invalidPath(linkRelPath),
                           "Sidecar symlink escape must throw with the sidecar path, not the image path")
        }
    }

    // MARK: - Helpers

    private func writeSidecar(relPath: String, body: String) throws {
        let url = skinDir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(body.utf8).write(to: url)
    }
}
