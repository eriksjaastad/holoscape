import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 2 — Asset path sandboxing (Requirement 1.6).
///
/// `SkinEngine.validateAssetPath` is the string-level gate that runs before
/// any filesystem touch. This suite hammers it with generated unsafe shapes
/// and confirms every shape throws; a matched set of safe shapes confirms
/// the gate doesn't reject legitimate relative paths.
///
/// Symlink-resolution (the second-half gate `assertPathResolvesInside`) is
/// exercised by `SkinEngineAssetLoadingTests`. This file focuses on the
/// string-shape invariants that must hold for every input.
@MainActor
final class PathSandboxingPropertyTests: XCTestCase {

    // SkinEngine needs main-actor init; build once and share across properties.
    private let engine = SkinEngine()

    // MARK: - Generators

    /// A random non-empty, non-slash path segment. Excludes `..` (tested
    /// separately) and characters that would produce HTTP/absolute shapes
    /// unrelated to the invariant under test.
    private static let safeSegment: Gen<String> = Gen<Character>.fromElements(of:
        Array("abcdefghijklmnopqrstuvwxyz0123456789_-.")
    ).proliferateNonEmpty.map { String($0) }.suchThat { seg in
        seg != ".." && !seg.hasPrefix("..") && !seg.contains("/") && !seg.isEmpty
    }

    /// A random safe relative path: one or more safe segments joined by `/`.
    private static let safeRelativePath: Gen<String> =
        safeSegment.proliferateNonEmpty.map { $0.joined(separator: "/") }

    /// A random absolute path (starts with `/`).
    private static let absolutePath: Gen<String> =
        safeRelativePath.map { "/" + $0 }

    /// An HTTP/HTTPS/file URL.
    private static let urlPath: Gen<String> = Gen<String>.fromElements(of: [
        "http://", "https://", "file://",
        "HTTP://", "HTTPS://", "FILE://",
        "Http://", "HttpS://",
    ]).flatMap { scheme in
        safeRelativePath.map { scheme + $0 }
    }

    /// A random path containing a `..` segment somewhere.
    private static let traversalPath: Gen<String> = Gen.zip(
        safeSegment.proliferate,
        safeSegment.proliferate
    ).map { (prefix: [String], suffix: [String]) in
        (prefix + [".."] + suffix).joined(separator: "/")
    }

    // MARK: - Unsafe-input properties

    func testAbsolutePathsAreRejected() {
        property("Absolute paths throw SkinAssetError.invalidPath") <- forAll(Self.absolutePath) { (path: String) in
            self.throwsInvalidPath(path)
        }
    }

    func testHTTPSchemesAreRejected() {
        property("http://, https://, and file:// URLs throw") <- forAll(Self.urlPath) { (path: String) in
            self.throwsInvalidPath(path)
        }
    }

    func testTraversalSegmentsAreRejected() {
        property("Any path containing a `..` segment throws") <- forAll(Self.traversalPath) { (path: String) in
            self.throwsInvalidPath(path)
        }
    }

    // MARK: - Safe-input property (negative control)

    func testSafeRelativePathsAreAccepted() {
        property("Safe relative paths do not throw") <- forAll(Self.safeRelativePath) { (path: String) in
            // Negative control: confirms we're not rejecting everything.
            // Safe paths don't touch the filesystem; validation is purely
            // string-shape here.
            do {
                try self.engine.validateAssetPath(path)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Helpers

    private func throwsInvalidPath(_ path: String) -> Bool {
        do {
            try engine.validateAssetPath(path)
            return false  // Should have thrown.
        } catch SkinAssetError.invalidPath(let reported) {
            // Error must carry the offending path so logs point at it.
            return reported == path
        } catch {
            return false  // Wrong error type.
        }
    }
}
