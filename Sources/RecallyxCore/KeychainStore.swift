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

    /// The bundle-id Keychain service all Recallyx items share. Custom-endpoint
    /// keys (addressed by a per-provider account) store under this same service.
    public static let recallyxService = "io.github.macrosak.recallyx"

    public static let openAIKey = KeychainStore(
        service: recallyxService,
        account: "openai-api-key"
    )

    public static let anthropicKey = KeychainStore(
        service: recallyxService,
        account: "anthropic-api-key"
    )

    public static let geminiKey = KeychainStore(
        service: recallyxService,
        account: "gemini-api-key"
    )

    /// Builds a store for a custom OpenAI-compatible provider's API key, keyed by
    /// the provider's per-id account (`ProviderConfig.customKeychainAccount(for:)`).
    public static func custom(account: String) -> KeychainStore {
        KeychainStore(service: recallyxService, account: account)
    }

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

    /// Non-interactive existence check: does this item exist AND can it be read
    /// *without* showing any UI? Returns `true` only on `errSecSuccess`.
    ///
    /// Unlike `read()`, this MUST NEVER pop a Keychain password prompt — it runs
    /// at launch (inside the settings decoder's provider-list migration), where a
    /// prompt is unacceptable. We pass `kSecUseAuthenticationUI: .fail` so a read
    /// that *would* require user interaction (e.g. the item's ACL was bound to a
    /// different/older code signature and no longer silently matches this build)
    /// fails with `errSecInteractionNotAllowed` instead of prompting. We also skip
    /// returning the data (`kSecReturnData: false`) — we only need presence, not
    /// the secret. Net behavior for the migration: key exists and is silently
    /// readable → seed; key absent OR reading would prompt → don't seed, no dialog.
    public func existsWithoutPrompt() -> Bool {
        var query: [String: Any] = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = false
        // `kSecUseAuthenticationUIFail` is the modern key (macOS 10.11+); it makes
        // any operation that would need UI return errSecInteractionNotAllowed
        // rather than presenting it. Compiles on the macOS 13+ floor.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
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
