import Foundation
import Security

// MARK: - 来源凭证存储
//
// ⚠️ 红线：**API Key 只存 Keychain，绝不进 SQLite、绝不发往本项目服务端。**
//
// 库里只有 instance id，密钥按 id 存 Keychain。删除来源时要连带删密钥 ——
// 否则换个同 id 的新来源会读到上一个的密钥（低概率但后果严重）。
//
// 与 AuthManager 里的 Keychain 各管各的：那边管登录态，这边管第三方 AI 凭证，
// 两者的生命周期与清理时机完全不同（登出要清 token，但不该清用户自配的 AI 密钥）。

public enum ProviderCredentials {

    private static let service = "com.chunland.app.ai.provider"

    private static func account(_ instanceId: String) -> String {
        "apikey:\(instanceId)"
    }

    // MARK: - 读写

    public static func apiKey(for instanceId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(instanceId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    public static func setAPIKey(_ key: String?, for instanceId: String) {
        guard let key, !key.isEmpty else {
            deleteAPIKey(for: instanceId)
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(instanceId),
        ]
        SecItemDelete(base as CFDictionary)

        var attrs = base
        attrs[kSecValueData as String] = Data(key.utf8)
        // 仅本机、解锁后可读：AI 密钥没有跨设备同步的必要，
        // 同步反而扩大了泄露面。
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public static func deleteAPIKey(for instanceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(instanceId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 删除来源时调用 —— 库里的行走 CASCADE，密钥要手动清。
    public static func purge(instanceIds: [String]) {
        instanceIds.forEach { deleteAPIKey(for: $0) }
    }
}
