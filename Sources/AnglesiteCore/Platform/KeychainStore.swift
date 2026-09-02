// Darwin implementation of the SecretStore seam. The whole file compiles out on
// platforms without the Security framework.
#if canImport(Security)
import Foundation
import LocalAuthentication
import Security

/// Stores secrets in the user's login keychain via `SecItem` (generic-password class).
///
/// One instance per service name; the service identifies the app to the keychain UI ("Anglesite
/// wants to use 'Anglesite Cloudflare API token'…"). Production uses the default service
/// `io.dwk.anglesite` to match the app's bundle id; tests pass a scratch service per case so
/// they don't collide with the real user's keychain entries.
///
/// All operations are synchronous — `SecItemCopyMatching` / `SecItemAdd` block while the keychain
/// resolves access. Callers from actor-isolated code should treat reads/writes as fast (no I/O
/// beyond an in-process system call) but should not hold a non-cancellable lock around them; the
/// first write after a fresh login may surface a Keychain Access prompt.
///
/// Security notes:
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the token off iCloud Keychain and
///   inaccessible while the Mac is locked.
/// - The token must never be logged. `DeployCommand` passes the Cloudflare token via
///   `environment` (which is opaque to the supervisor's stdout/stderr pump), so it never reaches
///   `LogCenter`. The GitHub token (#653) takes a different path with the same invariant but a
///   different mechanism: `InProcessGit` hands it to libgit2 through a `Credentials.plaintext`
///   push callback — never interpolated into a URL, error string, or log line it constructs — so
///   it likewise never reaches `LogCenter`, though its blast radius differs (an in-process
///   credential callback vs. an opaque subprocess environment variable).
public struct KeychainStore: SecretStore {
    /// Keychain failures surfaced to callers. Deliberately small: the expected "misses"
    /// (`errSecItemNotFound` on read/delete) are mapped to `nil`/no-op per the `SecretStore`
    /// contract, so anything that reaches this type is genuinely exceptional.
    public enum Error: Swift.Error, Equatable {
        /// `SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` returned a
        /// non-success `OSStatus`. The raw value is carried so test assertions can pin it down.
        case unhandled(OSStatus)
        /// A read returned data that didn't decode as UTF-8. Should never happen for tokens we
        /// wrote ourselves, but guards against a foreign actor having scribbled in our slot.
        case invalidUTF8
    }

    /// Default service identifier. Matches the app's bundle id.
    public static let defaultService = "io.dwk.anglesite"

    /// Account key for the Cloudflare API token. Forwarded from the portable
    /// `SecretAccounts` namespace (the shared slot definition since the SecretStore seam).
    public static let cloudflareTokenAccount = SecretAccounts.cloudflareToken

    /// The keychain access group that lets `Anglesite.app` and its `AnglesiteRemote` login-item
    /// helper read the *same* `SecretAccounts.devicePairingKey` entry (#1208 P2).
    ///
    /// Passed by both pairing-key call sites — `DevicePairingSettingsView.generateQRCode()` and
    /// `anglesite-remote-helper`'s `helperSigningKey()` — and by nothing else; every other caller
    /// keeps the default `accessGroup: nil`. Keychain Sharing needs no Apple Developer *portal*
    /// capability (every App ID carries it implicitly, unlike CloudKit or App Groups).
    ///
    /// - Important: it does still need a **provisioning profile to sign**, so only some builds
    ///   carry it. `Resources/Anglesite.entitlements` and `Resources/AnglesiteRemote.entitlements`
    ///   (both Release) declare it; the CI-safe default Debug files deliberately do not, because
    ///   Xcode fails the build outright on an entitlement it can't back with a profile — which
    ///   would break this repo's no-Apple-account clone-and-build promise. On such a build
    ///   `SecItem` rejects every operation carrying this group, typically
    ///   `errSecMissingEntitlement` surfaced as ``Error/unhandled(_:)``, and the two call sites
    ///   degrade loudly rather than silently reading a per-bundle key that pairing could never
    ///   verify. A local Debug run can opt in via `Resources/Anglesite-Debug-iCloud.entitlements`
    ///   plus `Resources/AnglesiteRemote-Debug-Keychain.entitlements` — see
    ///   `xcconfig/Signing-Debug.local.xcconfig.example`, and
    ///   `Resources/AnglesiteRemote.entitlements` ▸ step 2 for the whole finding.
    ///
    /// Written team-prefixed because that is the *runtime* form: an entitlements plist spells the
    /// group `$(AppIdentifierPrefix)io.dwk.anglesite.shared` and the build expands the prefix, but
    /// nothing expands it here, and `SecItem` matches the expanded string. Team `M34HBJZNYA` is
    /// therefore load-bearing: it is the team carrying the paid Apple Developer Program membership
    /// that this epic's portal-gated capabilities need — CloudKit, App Groups, and this group's own
    /// provisioning-profile requirement above — so it is the team the entitlements declaring this
    /// group have to be signed under once a suitable certificate for it is in place. Change the
    /// signing team and this constant must change with it (and with every entitlements file that
    /// declares the group), or the two processes silently fall back to seeing no shared item at all
    /// rather than failing loudly.
    public static let sharedPairingAccessGroup = "M34HBJZNYA.io.dwk.anglesite.shared"

    /// The `kSecAttrService` under which every entry of this store lives — the namespace
    /// separating this store's slots from any other keychain items.
    public let service: String

    /// The `kSecAttrAccessGroup` every query carries, or `nil` to let the system apply the
    /// process's default group. See ``init(service:accessGroup:)``.
    public let accessGroup: String?

    /// Creates a store scoped to `service` and, optionally, to a shared keychain access group.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` namespace. Production uses the default; tests pass a
    ///     per-case scratch service so they never read or clobber the user's real entries.
    ///   - accessGroup: The `kSecAttrAccessGroup` to scope every read/write/delete to. `nil` (the
    ///     default, and what every caller but the two device-pairing ones passes) omits the
    ///     attribute entirely, which leaves the system's behavior untouched: a sandboxed process
    ///     gets its own bundle-ID-derived group, so two bundles never see each other's items even
    ///     with identical service/account strings. Pass a group only where *both* bundles carry it
    ///     in a `keychain-access-groups` entitlement — see ``sharedPairingAccessGroup``, the only
    ///     group this app declares. Passing a group the process is not entitled to makes `SecItem`
    ///     reject the operation (typically `errSecMissingEntitlement`, surfaced as
    ///     ``Error/unhandled(_:)``), so this is not something to switch on speculatively, and a
    ///     caller that does pass one must have a sensible failure path for the builds that lack it.
    public init(service: String = KeychainStore.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: Reads

    /// Returns the stored secret for `account`, or `nil` if no entry exists.
    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else { throw Error.invalidUTF8 }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unhandled(status)
        }
    }

    /// Same as ``read(account:)``, except a query that would need to show a system authorization
    /// prompt — e.g. the "$App wants to use your confidential information…" dialog macOS shows
    /// when the item's per-app ACL no longer trusts the caller's code signature, which happens on
    /// every rebuild of an ad-hoc-signed Debug build (#1705) — fails immediately with `nil` instead
    /// of blocking this thread until a human answers a prompt they may never see (there is no
    /// indication anywhere in the app's UI that one is pending). `LAContext.interactionNotAllowed`
    /// makes `SecItemCopyMatching` itself refuse to display that UI, surfacing
    /// `errSecInteractionNotAllowed` synchronously rather than blocking on it.
    public func readNonInteractive(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else { throw Error.invalidUTF8 }
            return string
        case errSecItemNotFound, errSecInteractionNotAllowed:
            return nil
        default:
            throw Error.unhandled(status)
        }
    }

    // MARK: Writes

    /// Writes `value` for `account`, replacing any existing entry. An empty `value` deletes
    /// the entry — keychain entries for "" are nonsensical and would round-trip differently
    /// from `read → nil`.
    public func write(_ value: String, account: String) throws {
        if value.isEmpty {
            try delete(account: account)
            return
        }
        guard let data = value.data(using: .utf8) else { throw Error.invalidUTF8 }

        let existing = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(existing as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(account: account)
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.unhandled(addStatus) }
        default:
            throw Error.unhandled(updateStatus)
        }
    }

    /// Removes the stored entry for `account`. No-op if no entry exists.
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Error.unhandled(status)
        }
    }

    // Cloudflare token convenience (readCloudflareToken()/writeCloudflareToken(_:)/
    // clearCloudflareToken()) comes from the SecretStore protocol extension.

    // MARK: Internals

    /// The attribute dictionary identifying one slot — the shared prefix of every
    /// `SecItemCopyMatching`/`SecItemAdd`/`SecItemUpdate`/`SecItemDelete` this type issues.
    ///
    /// `internal` rather than `private` only so the test suite can assert on the constructed
    /// dictionary: whether `kSecAttrAccessGroup` is present is not otherwise observable from a
    /// process that isn't entitled to the group it names.
    func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        // Omitted, not set to a placeholder, when `accessGroup` is nil: an absent
        // kSecAttrAccessGroup means "the process's default group", which is what every caller
        // outside the device-pairing pair relies on.
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
#endif
