import Foundation
import Security

/// 密钥存储抽象：生产用 Keychain，测试用内存实现。
public protocol SecretStoring: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String)
}

public enum SecretAccount {
    public static let translationAPIKey = "translationAPIKey"
    public static let cloudSyncToken = "cloudSyncToken"

    public static func aiModelProfileAPIKey(id: String) -> String {
        "aiModelProfile.\(id).apiKey"
    }
}

/// 登录钥匙串中的通用密码项，不落磁盘明文。
public struct KeychainSecretStore: SecretStoring {
    private let service: String

    public init(service: String = "com.dontstool.secrets") {
        self.service = service
    }

    public func secret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else {
            delete(account: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
