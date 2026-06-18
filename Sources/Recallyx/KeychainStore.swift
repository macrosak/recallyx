import Foundation
import Security

/// Thin wrapper around generic-password Keychain items. One instance per
/// (service, account) pair. Copied from AI Replace.
struct KeychainStore {
    let service: String
    let account: String

    static let openAIKey = KeychainStore(
        service: "io.github.macrosak.recallyx",
        account: "openai-api-key"
    )

    static let anthropicKey = KeychainStore(
        service: "io.github.macrosak.recallyx",
        account: "anthropic-api-key"
    )

    func read() -> String? {
        var query: [String: Any] = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                Log.error("Keychain read failed status=\(status)")
            }
            return nil
        }
        return string
    }

    @discardableResult
    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            Log.error("Keychain update failed status=\(updateStatus)")
            return false
        }

        var add = baseQuery
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.error("Keychain add failed status=\(addStatus)")
            return false
        }
        return true
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.error("Keychain delete failed status=\(status)")
            return false
        }
        return true
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
