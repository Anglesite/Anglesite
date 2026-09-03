import Foundation
import AnglesiteCore

/// An in-memory `SecretStore` for tests needing a real write-then-read round trip without the
/// Keychain — used by `CloudflareOAuthCredentialTests`, `CloudflareOAuthTokenSourceTests`, and
/// `DeployModelTests` (three different test targets; kept here, in the shared support target,
/// rather than duplicated).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    /// Pre-seeds `account` (default `SecretAccounts.cloudflareToken`) with `token`, or leaves the
    /// store empty when `token` is nil — the shape most call sites need: a read-only stand-in for
    /// "the Cloudflare token is/isn't configured".
    public convenience init(token: String?, account: String = SecretAccounts.cloudflareToken) {
        self.init()
        if let token {
            try? write(token, account: account)
        }
    }

    public func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }
    public func write(_ value: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty { storage.removeValue(forKey: account) } else { storage[account] = value }
    }
    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
