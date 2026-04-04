import XCTest
@testable import Holoscape

final class AuthEnvironmentEdgeCaseTests: XCTestCase {

    func testOAuthEnvironmentHasRequiredVars() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertNotNil(env["PATH"])
        XCTAssertNotNil(env["HOME"])
        XCTAssertNotNil(env["SHELL"])
        XCTAssertNotNil(env["TERM"])
        XCTAssertNotNil(env["LANG"])
    }

    func testOAuthNeverLeaksAPIKey() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertNil(env["ANTHROPIC_API_KEY"], "OAuth mode must never set API key")

        // Also check no other env var accidentally contains an API key pattern
        for (key, value) in env {
            XCTAssertFalse(
                value.hasPrefix("sk-ant-"),
                "Env var \(key) contains what looks like an API key"
            )
        }
    }

    func testAPIKeyEnvironmentContainsExactKey() {
        let testKey = "sk-ant-test-key-12345"
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .apiKey(testKey),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(env["ANTHROPIC_API_KEY"], testKey)
    }

    func testAPIKeyWithEmptyString() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .apiKey(""),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "")
    }

    func testEnvironmentIsClean() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        // Should only contain the designated variables
        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG"]
        for key in env.keys {
            XCTAssertTrue(allowedKeys.contains(key), "Unexpected env var: \(key)")
        }
    }

    func testAPIKeyEnvironmentIsCleanPlusKey() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .apiKey("test"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "ANTHROPIC_API_KEY"]
        for key in env.keys {
            XCTAssertTrue(allowedKeys.contains(key), "Unexpected env var: \(key)")
        }
    }

    func testPathIncludesHomebrew() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let path = env["PATH"]!
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "PATH should include Homebrew")
    }

    func testTermIsXterm256Color() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(env["TERM"], "xterm-256color")
    }

    func testWorkingDirectoryDoesNotAffectEnvironment() {
        let env1 = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let env2 = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/Users/test/projects")
        )

        // Environment should be identical regardless of working directory
        XCTAssertEqual(env1, env2)
    }
}
