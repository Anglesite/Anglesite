// Exercises the same Darwin-only Security framework KeychainStore wraps; compiles out
// off-Darwin, matching KeychainStore.swift's own gate.
#if canImport(Security)
import Foundation
import Security
import AnglesiteCore

/// A `KeychainStore` scoped to a fresh, per-case scratch service name, with `cleanup()` removing
/// every item the test wrote under it.
///
/// Every `KeychainStore`-using test under `Tests/` used to hand-roll
/// `KeychainStore(service: "io.dwk.anglesite.test-\(UUID().uuidString)")` and never delete what it
/// wrote — the Keychain-side twin of the `UserDefaults` leak `TemporaryUserDefaults` fixes (#1727).
/// Unlike that leak, a `SecItemDelete` scoped to `kSecAttrService` alone (no `kSecAttrAccount`,
/// unlike `KeychainStore`'s own per-account `baseQuery`) genuinely removes every matching item on
/// the first call — there is no cfprefsd-style "empty stub survives the delete" quirk to work
/// around here, so `cleanup()` is a single query.
///
/// Call `cleanup()` explicitly (`defer { scratch.cleanup() }` right after creation) rather than
/// relying on `deinit`: the `KeychainStore` handed to production code is a plain struct, so nothing
/// observes this wrapper going out of scope, and an ARC-timed delete could fire before a test that
/// deliberately re-reads the item back has run.
public struct TemporaryKeychainStore {
    /// The store under test — pass wherever production code expects a `SecretStore` or
    /// `KeychainStore`.
    public let store: KeychainStore

    private let service: String

    /// Creates a scratch store scoped to a fresh `io.dwk.anglesite.test-<UUID>` service name.
    public init() {
        service = "io.dwk.anglesite.test-\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }

    /// Deletes every item written under this instance's scratch service. Safe to call even when
    /// nothing was ever written.
    public func cleanup() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
