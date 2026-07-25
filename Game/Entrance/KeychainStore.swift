import Foundation
import Security
import GameCore

/// Stores connector credentials as one Keychain item. Credential values are never
/// written to UserDefaults or to a file owned by the app.
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

    init(service: String = "com.antest1.game.connector-credentials") {
        self.service = service
    }

    func save(_ credentials: Credentials, for connector: BrowserConstants.Connector) throws {
        guard !credentials.id.isEmpty, !credentials.password.isEmpty else {
            throw StoreError.invalidCredentials
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(credentials)
        } catch {
            throw StoreError.encodingFailed(error.localizedDescription)
        }

        let query = baseQuery(for: connector)
        let update: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
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
    }

    func load(for connector: BrowserConstants.Connector) throws -> Credentials? {
        var query = baseQuery(for: connector)
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
        let status = SecItemDelete(baseQuery(for: connector) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.securityStatus(operation: "删除", status: status)
        }
    }

    private func baseQuery(for connector: BrowserConstants.Connector) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connector.rawValue
        ]
    }
}
