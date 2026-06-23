import Foundation
import Security

/// Thin wrapper around generic-password Keychain items. One instance per
/// (service, account) pair. Copied from AI Replace.
public struct KeychainStore {
    public let service: String
    public let account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static let openAIKey = KeychainStore(
        service: "io.github.macrosak.recallyx",
        account: "openai-api-key"
    )

    public static let anthropicKey = KeychainStore(
        service: "io.github.macrosak.recallyx",
        account: "anthropic-api-key"
    )

    public static let geminiKey = KeychainStore(
        service: "io.github.macrosak.recallyx",
        account: "gemini-api-key"
    )

    public func read() -> String? {
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
    public func write(_ value: String) -> Bool {
        let data = Data(value.utf8)

        // Delete any existing item before re-adding so the new item's access
        // control list is recreated against the current code signature.
        // SecItemUpdate refreshes the secret but keeps the original ACL, which
        // — when the item was first created by an older/ad-hoc-signed build —
        // mismatches the current signature and reprompts on every reinstall.
        // A fresh SecItemAdd binds the ACL to the current designated
        // requirement, self-healing the stale entry after one save.
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            Log.error("Keychain delete-before-add failed status=\(deleteStatus)")
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
    public func delete() -> Bool {
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
