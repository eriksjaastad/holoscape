import XCTest
import SwiftCheck
@testable import Holoscape

final class AuthEnvironmentPropertyTests: XCTestCase {
    // Feature: holoscape-native-terminal, Property 8: OAuth environment omits API key
    func testOAuthEnvironmentOmitsAPIKey() {
        property("OAuth environment never contains ANTHROPIC_API_KEY") <- forAll { (path: String) in
            let dir = URL(fileURLWithPath: path.isEmpty ? "/tmp" : path)
            let env = AuthEnvironmentBuilder.buildEnvironment(for: .oauth, workingDirectory: dir)
            return env["ANTHROPIC_API_KEY"] == nil
        }
    }

    // Feature: holoscape-native-terminal, Property 9: API key environment injects correct key
    func testAPIKeyEnvironmentInjectsCorrectKey() {
        property("API key environment contains exact key provided") <- forAll { (key: String) in
            guard !key.isEmpty else { return true }
            let env = AuthEnvironmentBuilder.buildEnvironment(
                for: .apiKey(key),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            return env["ANTHROPIC_API_KEY"] == key
        }
    }

    // Feature: holoscape-native-terminal, Property 10: Clean environment contains only designated variables
    func testCleanEnvironmentContainsOnlyDesignatedVars() {
        let designatedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG"]
        let designatedKeysWithAPI: Set<String> = designatedKeys.union(["ANTHROPIC_API_KEY"])

        property("OAuth env has exactly designated keys") <- forAll { (path: String) in
            let dir = URL(fileURLWithPath: path.isEmpty ? "/tmp" : path)
            let env = AuthEnvironmentBuilder.buildEnvironment(for: .oauth, workingDirectory: dir)
            return Set(env.keys) == designatedKeys
        }

        property("API key env has exactly designated keys plus API key") <- forAll { (key: String) in
            guard !key.isEmpty else { return true }
            let env = AuthEnvironmentBuilder.buildEnvironment(
                for: .apiKey(key),
                workingDirectory: URL(fileURLWithPath: "/tmp")
            )
            return Set(env.keys) == designatedKeysWithAPI
        }
    }
}
