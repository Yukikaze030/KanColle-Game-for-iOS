import Foundation
import Security
import GameCore

/// Stores one shared credential for every connector. Older builds used one
/// Keychain account per connector; `load` migrates the first legacy value it
/// finds into the shared item so users do not need to enter it again.
struct KeychainStore: Sendable {
    struct Credentials: Codable, Equatable, Sendable {
        let id: String
        let password: String
    }

    enum StoreError: LocalizedError, Equatable {
        case invalidCredentials
        case unexpectedData
        case encodingFailed(String)
        case securityStatus(operation: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "账号和密码不能为空。"
            case .unexpectedData:
                return "钥匙串中的凭证格式无效。"
            case .encodingFailed(let detail):
                return "无法编码凭证：\(detail)"
            case .securityStatus(let operation, let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串\(operation)失败（\(status)）：\(message)"
            }
        }
    }

    private let service: String
    private static let sharedAccount = "shared"

    init(service: String = "com.antest1.game.connector-credentials") {
        self.service = service
    }

    func save(_ credentials: Credentials, for connector: BrowserConstants.Connector) throws {
        _ = connector // Kept in the API so existing callers need no special branch.
        guard !credentials.id.isEmpty, !credentials.password.isEmpty else {
            throw StoreError.invalidCredentials
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(credentials)
        } catch {
            throw StoreError.encodingFailed(error.localizedDescription)
        }

        let query = baseQuery(account: Self.sharedAccount)
        let update: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = encoded
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.securityStatus(operation: "保存", status: addStatus)
            }
        default:
            throw StoreError.securityStatus(operation: "更新", status: updateStatus)
        }

        // A successful shared write makes connector-specific legacy records
        // unnecessary. Cleanup is best effort because the new credential is
        // already safely persisted.
        deleteLegacyItems()
    }

    func load(for connector: BrowserConstants.Connector) throws -> Credentials? {
        if let shared = try load(account: Self.sharedAccount) {
            return shared
        }

        // Prefer the currently selected connector, then inspect the other old
        // accounts. All three connectors use the same DMM credentials.
        let legacyOrder = [connector] + BrowserConstants.Connector.allCases.filter { $0 != connector }
        for legacyConnector in legacyOrder {
            guard let legacy = try load(account: legacyConnector.rawValue) else { continue }
            try save(legacy, for: connector)
            return legacy
        }
        return nil
    }

    private func load(account: String) throws -> Credentials? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.securityStatus(operation: "读取", status: status)
        }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
            throw StoreError.unexpectedData
        }
        return credentials
    }

    func delete(for connector: BrowserConstants.Connector) throws {
        _ = connector
        try deleteAll()
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.securityStatus(operation: "删除", status: status)
        }
    }

    private func deleteLegacyItems() {
        for connector in BrowserConstants.Connector.allCases {
            SecItemDelete(baseQuery(account: connector.rawValue) as CFDictionary)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
