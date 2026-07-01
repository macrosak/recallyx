import Foundation
import Security
import Testing
@testable import RecallyxCore

/// Hermetic coverage for `KeychainStore.write()`'s requirement-based-ACL
/// hardening. The real login keychain needs an unlocked keychain + a signing
/// identity CI lacks, so these drive the injectable `addItem`/`deleteItem`/
/// `makeAccess` seams instead of touching the system keychain. The actual
/// no-reprompt-on-reinstall behavior is OS-level and verified on-device.
@Suite("KeychainStore")
struct KeychainStoreTests {

    // MARK: - The requirement-access helper

    #if os(macOS)
    /// Under normal conditions (a built/signed-or-ad-hoc test binary) the helper
    /// either returns a usable `SecAccess` or — for an unsigned binary — `nil`.
    /// It must never crash or hang; calling it twice is stable. We can't assert
    /// non-nil unconditionally (the test runner may be unsigned), so we assert it
    /// runs and is internally consistent: a returned value is a real `SecAccess`.
    @Test func selfRequirementAccessIsBestEffort() {
        let access = KeychainStore.makeSelfRequirementAccess()
        if let access {
            // A returned object is a genuine SecAccess (right CFType).
            #expect(CFGetTypeID(access) == SecAccessGetTypeID())
        }
        // Idempotent: a second call behaves the same way (both nil or both not).
        let again = KeychainStore.makeSelfRequirementAccess()
        #expect((access == nil) == (again == nil))
    }
    #endif

    // MARK: - write → read round-trip via the seams

    /// With the keychain calls stubbed, `write()` deletes-then-adds and the
    /// stored secret is what a matching read would return. Drives the seams so no
    /// real keychain is touched.
    @Test func writeDeletesThenAddsTheSecret() {
        var deleteCalls = 0
        var addedData: Data?

        var store = KeychainStore(service: "test", account: "rt")
        store.deleteItem = { _ in deleteCalls += 1; return errSecItemNotFound }
        store.addItem = { dict, _ in
            let d = dict as NSDictionary
            addedData = d[kSecValueData as String] as? Data
            return errSecSuccess
        }
        #if os(macOS)
        store.makeAccess = { nil }  // exercise the plain-add branch here
        #endif

        #expect(store.write("sk-secret-123") == true)
        #expect(deleteCalls == 1)
        #expect(addedData == Data("sk-secret-123".utf8))
    }

    #if os(macOS)
    /// Builds a non-nil `SecAccess` sentinel to inject into `makeAccess` so the
    /// attach / retry paths run deterministically. `SecAccessCreate` builds an
    /// in-memory ACL object (it does NOT touch the keychain), so it works even
    /// in the locked CI keychain env; an empty trusted-app list is enough — the
    /// tests only care that a non-nil access reaches the add query. `#require`
    /// FAILS the test (never skips) if the object can't be built.
    private func makeSentinelAccess() throws -> SecAccess {
        var access: SecAccess?
        let status = SecAccessCreate("Test" as CFString, [] as CFArray, &access)
        #expect(status == errSecSuccess)
        return try #require(access)
    }

    /// When `makeAccess` yields an access, it is attached to the add query under
    /// `kSecAttrAccess` (the requirement-based-ACL path).
    @Test func writeAttachesAccessWhenAvailable() throws {
        let access = try makeSentinelAccess()

        var attachedAccess: CFTypeRef?
        var store = KeychainStore(service: "test", account: "acl")
        store.deleteItem = { _ in errSecItemNotFound }
        store.makeAccess = { access }
        store.addItem = { dict, _ in
            attachedAccess = (dict as NSDictionary)[kSecAttrAccess as String] as CFTypeRef?
            return errSecSuccess
        }

        #expect(store.write("v") == true)
        #expect(attachedAccess != nil)
    }

    /// Fallback: when `makeAccess` returns nil (ACL construction failed), the
    /// add carries NO `kSecAttrAccess` and the write still succeeds.
    @Test func writeFallsBackToDefaultACLWhenAccessNil() {
        var sawAccessKey = true
        var store = KeychainStore(service: "test", account: "fallback")
        store.deleteItem = { _ in errSecItemNotFound }
        store.makeAccess = { nil }
        store.addItem = { dict, _ in
            sawAccessKey = (dict as NSDictionary)[kSecAttrAccess as String] != nil
            return errSecSuccess
        }

        #expect(store.write("v") == true)
        #expect(sawAccessKey == false)
    }

    /// Lockout safety: if the add WITH the requirement ACL fails, `write()`
    /// retries once with the default ACL and still reports success — saving a
    /// key must never fail because the hardening failed.
    @Test func writeRetriesWithDefaultACLWhenHardenedAddFails() throws {
        let access = try makeSentinelAccess()

        var attempts: [Bool] = []  // per add: did it carry kSecAttrAccess?
        var store = KeychainStore(service: "test", account: "retry")
        store.deleteItem = { _ in errSecItemNotFound }
        store.makeAccess = { access }
        store.addItem = { dict, _ in
            let hadAccess = (dict as NSDictionary)[kSecAttrAccess as String] != nil
            attempts.append(hadAccess)
            // First (hardened) add fails; the default-ACL retry succeeds.
            return hadAccess ? errSecParam : errSecSuccess
        }

        #expect(store.write("v") == true)
        #expect(attempts == [true, false])  // hardened add, then default-ACL retry
    }
    #endif

    /// A non-retryable add failure (no access attached) propagates as `false`.
    @Test func writeReturnsFalseWhenPlainAddFails() {
        var store = KeychainStore(service: "test", account: "fail")
        store.deleteItem = { _ in errSecItemNotFound }
        #if os(macOS)
        store.makeAccess = { nil }
        #endif
        store.addItem = { _, _ in errSecParam }

        #expect(store.write("v") == false)
    }
}
