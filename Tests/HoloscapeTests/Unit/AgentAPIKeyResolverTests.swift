import XCTest
@testable import Holoscape

final class AgentAPIKeyResolverTests: XCTestCase {
    func testResolverReturnsAPIKeyAuthFromKeychainStore() throws {
        let resolver = AgentAPIKeyResolver(store: StubAgentAPIKeyStore(value: "sk-ant-from-keychain"))

        let authType = try resolver.authType()

        guard case .apiKey(let key) = authType else {
            return XCTFail("Expected API-key auth type")
        }
        XCTAssertEqual(key, "sk-ant-from-keychain")
    }

    func testResolverFailsClosedWhenKeychainHasNoKey() {
        let resolver = AgentAPIKeyResolver(store: StubAgentAPIKeyStore(value: nil))

        XCTAssertThrowsError(try resolver.authType()) { error in
            XCTAssertEqual(
                error as? AgentAPIKeyResolver.ResolveError,
                .missingKey(service: AgentAPIKeyStore.defaultService, account: AgentAPIKeyStore.defaultAccount)
            )
        }
    }

    func testResolverDoesNotConvertKeychainErrorsIntoEmptyAPIKeys() {
        let resolver = AgentAPIKeyResolver(store: ThrowingAgentAPIKeyStore())

        XCTAssertThrowsError(try resolver.authType()) { error in
            XCTAssertEqual(error as? AgentAPIKeyStore.StoreError, .invalidStoredData)
        }
    }
}

private struct StubAgentAPIKeyStore: AgentAPIKeyReadable {
    let value: String?

    func apiKey() throws -> String? {
        value
    }
}

private struct ThrowingAgentAPIKeyStore: AgentAPIKeyReadable {
    func apiKey() throws -> String? {
        throw AgentAPIKeyStore.StoreError.invalidStoredData
    }
}
