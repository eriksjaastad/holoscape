import XCTest
@testable import Holoscape

final class AuthEnvironmentBuilderTests: XCTestCase {
    func testOAuthEnvironmentOmitsAPIKey() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNotNil(env["PATH"])
        XCTAssertNotNil(env["HOME"])
        XCTAssertNotNil(env["SHELL"])
        XCTAssertNotNil(env["TERM"])
        XCTAssertNotNil(env["LANG"])
    }

    func testAPIKeyEnvironmentInjectsKey() {
        let testKey = "sk-ant-test-key-12345"
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .apiKey(testKey),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], testKey)
    }

    func testCleanEnvironmentContainsOnlyDesignatedVars() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let expectedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG"]
        XCTAssertEqual(Set(env.keys), expectedKeys)
    }

    func testAPIKeyEnvironmentContainsOnlyDesignatedVarsPlus() {
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: .apiKey("test"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let expectedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "ANTHROPIC_API_KEY"]
        XCTAssertEqual(Set(env.keys), expectedKeys)
    }
}
