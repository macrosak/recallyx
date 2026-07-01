import Foundation
import Security

/// Thin wrapper around generic-password Keychain items. One instance per
/// (service, account) pair. Copied from AI Replace.
public struct KeychainStore {
    public let service: String
    public let account: String

    /// Seams so `write()`'s mechanics can be exercised hermetically — the real
    /// login keychain needs an unlocked keychain + a signing identity that CI
    /// lacks. Production uses the real `Sec*` calls (the defaults below).
    /// `addItem` mirrors `SecItemAdd`; `deleteItem` mirrors `SecItemDelete`;
    /// `makeAccess` builds the requirement-based access (or returns `nil` to
    /// force the plain-ACL fallback). A test can stub these to verify the
    /// round-trip and the fallback without ever touching the real keychain.
    var addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
        SecItemAdd($0, $1)
    }
    var deleteItem: (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    #if os(macOS)
    var makeAccess: () -> SecAccess? = { KeychainStore.makeSelfRequirementAccess() }
    #endif

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
        let deleteStatus = deleteItem(baseQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            Log.error("Keychain delete-before-add failed status=\(deleteStatus)")
            return false
        }

        var add = baseQuery

        // Best-effort: bind the item's ACL to this app's *designated
        // requirement* (signing cert + bundle id) rather than its per-build
        // code hash. macOS "Always Allow" for a cert-signed app otherwise pins
        // the specific binary; every reinstall ships a new binary (new cdhash)
        // and re-prompts. A requirement-based ACL is satisfied by any
        // identically-signed rebuild, so the grant survives reinstalls. (For an
        // ad-hoc build the captured record still pins the cdhash — same as the
        // default ACL — so this is a harmless no-op there; see makeAccess.)
        // If the access can't be built (older OS, unsigned binary, any failing
        // Security call) we fall through to a plain add with the default ACL —
        // saving a key must NEVER fail because the hardening did.
        #if os(macOS)
        let access = makeAccess()
        if let access {
            add[kSecAttrAccess as String] = access
        }
        #endif

        add[kSecValueData as String] = data
        let addStatus = addItem(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            #if os(macOS)
            // If the add failed with the requirement ACL attached, retry once
            // with the default ACL so the save still succeeds.
            if access != nil {
                Log.error("Keychain add with requirement ACL failed status=\(addStatus); retrying with default ACL")
                add[kSecAttrAccess as String] = nil
                let retryStatus = addItem(add as CFDictionary, nil)
                if retryStatus == errSecSuccess { return true }
                Log.error("Keychain add (default ACL) failed status=\(retryStatus)")
                return false
            }
            #endif
            Log.error("Keychain add failed status=\(addStatus)")
            return false
        }
        return true
    }

    @discardableResult
    public func delete() -> Bool {
        let status = deleteItem(baseQuery as CFDictionary)
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

    #if os(macOS)
    /// Builds a `SecAccess` whose ACL trusts this app via an explicit
    /// trusted-application record, so a read by an identically-signed rebuild is
    /// authorized without the per-build re-prompt the *default* `SecItemAdd` ACL
    /// produces. For a code-signed app `SecTrustedApplicationCreateFromPath(nil,…)`
    /// captures the running code's signing identity (its designated requirement:
    /// signing cert + bundle id), not its per-build code hash — so the grant is
    /// satisfied by any "Recallyx Dev"-signed build across reinstalls.
    ///
    /// Best-effort: returns `nil` on any failing legacy Security call so the
    /// caller falls back to a plain default-ACL add. We require a valid
    /// designated requirement first (`SecCodeCopyDesignatedRequirement`
    /// succeeds); that guard only bails for a *truly unsigned* binary. An
    /// ad-hoc-signed build DOES have a designated requirement (a cdhash `H"…"`
    /// DR), so the guard passes for it and we proceed — but the captured
    /// trusted-app record then pins that build's cdhash, which is equivalent to
    /// the default `SecItemAdd` ACL: no reinstall benefit, no harm. The
    /// reinstall win is real only for a **cert-signed** build, where the record
    /// captures the stable signing identity that survives rebuilds. For ad-hoc
    /// the actual fix is the keychain-access-groups entitlement (an Apple
    /// Developer account) — out of reach here, so attaching the harmless
    /// hash-pinned access is an accepted no-op.
    ///
    /// The `SecTrustedApplication*` / `SecAccess*` APIs are deprecated since
    /// 10.10 but remain functional on the macOS file keychain; they don't exist
    /// on iOS (a future iOS target uses access groups), hence `#if os(macOS)`.
    ///
    /// NOTE: the *explicit*-requirement variant (`SecTrustedApplicationSet-
    /// Requirement`, which would pin trust to an arbitrary requirement string)
    /// is SPI that is absent from the Command Line Tools SDK and unresolvable at
    /// runtime on macOS 26 — so this relies on the signed-binary auto-capture
    /// behavior of `…CreateFromPath(nil,…)`. Whether that defeats the reinstall
    /// re-prompt is OS-level and must be verified on-device (see the manual gate).
    static func makeSelfRequirementAccess() -> SecAccess? {
        // Precondition: the running code is signed (has a designated
        // requirement). This fails ONLY for a truly unsigned binary — an
        // ad-hoc build still has a DR (its cdhash), so the guard passes for it
        // too. For a cert-signed build the DR is the stable signing identity
        // (cert + identifier, survives rebuilds); for ad-hoc it's the per-build
        // cdhash and the resulting ACL matches only this exact binary (no
        // reinstall benefit, but harmless). Unsigned → bail to the default add.
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
              let code = selfCode else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let still = staticCode else { return nil }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(still, SecCSFlags(), &requirement) == errSecSuccess,
              requirement != nil else { return nil }

        // A trusted application for *this* process. For a signed binary the
        // record captures the signing identity, so it matches any rebuild
        // sharing that identity rather than only this exact binary.
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApp) == errSecSuccess,
              let app = trustedApp else { return nil }

        let trustedApps = [app] as CFArray

        // A SecAccess seeded with that trusted app. SecAccessCreate already
        // wires it into the default decrypt/encrypt ACLs; that's exactly the
        // explicit trusted-app list we want on the new item.
        var access: SecAccess?
        guard SecAccessCreate("Recallyx" as CFString, trustedApps, &access) == errSecSuccess,
              let acc = access else { return nil }

        return acc
    }
    #endif
}
