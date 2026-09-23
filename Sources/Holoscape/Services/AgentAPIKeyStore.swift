import Foundation
import Security

protocol AgentAPIKeyReadable {
    func apiKey() throws -> String?
}

struct AgentAPIKeyStore: AgentAPIKeyReadable {
    enum StoreError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidStoredData
    }

    static let defaultService = "com.holoscape.agent-api-key"
    static let defaultAccount = "anthropic"

    let service: String
    let account: String

    init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    func apiKey() throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll(keepingCapacity: false)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw StoreError.invalidStoredData
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }
}

struct AgentAPIKeyResolver {
    enum ResolveError: Error, Equatable {
        case missingKey(service: String, account: String)
    }

    let store: any AgentAPIKeyReadable
    let service: String
    let account: String

    init(
        store: any AgentAPIKeyReadable = AgentAPIKeyStore(),
        service: String = AgentAPIKeyStore.defaultService,
        account: String = AgentAPIKeyStore.defaultAccount
    ) {
        self.store = store
        self.service = service
        self.account = account
    }

    func authType() throws -> AgentAuthType {
        guard let key = try store.apiKey() else {
            throw ResolveError.missingKey(service: service, account: account)
        }
        return .apiKey(key)
    }
}
