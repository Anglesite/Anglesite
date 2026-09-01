import Foundation
import AnglesiteCore

/// A `SecretStore` that records *where* each read ran and can hold reads open, so a test can pin
/// the two properties #1705 is about: the Cloudflare token probe must not run its blocking read on
/// the main thread, and a read that hasn't answered yet must not stall the caller indefinitely.
///
/// Stands in for the real Keychain's worst behavior — `SecItemCopyMatching` parked in securityd's
/// authorization panel — without needing one. Writes round-trip into memory so a test can seed a
/// credential first; use `InMemorySecretStore` when neither recording nor gating is wanted.
public final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var readAccounts: [String] = []
    private var mainThreadReads = 0

    /// Guards the read gate. Separate from `lock` so a blocked reader never holds the lock the
    /// recording accessors need.
    private let gate = NSCondition()
    private var gateOpen: Bool

    /// - Parameter gated: When `true`, every read blocks until ``openGate()`` is called. Tests
    ///   that gate a read **must** open the gate before finishing (a `defer` is the usual place):
    ///   the probe's own queue is process-wide and serial, so a permanently blocked read would
    ///   stall every later probe in the same test process.
    public init(gated: Bool = false) {
        self.gateOpen = !gated
    }

    /// Lets every blocked and future read through. Idempotent.
    public func openGate() {
        gate.lock()
        gateOpen = true
        gate.broadcast()
        gate.unlock()
    }

    /// The accounts read so far, in order.
    public var accountsRead: [String] {
        lock.lock(); defer { lock.unlock() }
        return readAccounts
    }

    /// How many reads ran on the main thread — the count #1705 needs to be zero on the invisible
    /// publish path.
    public var mainThreadReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return mainThreadReads
    }

    public func read(account: String) throws -> String? {
        let onMainThread = Thread.isMainThread
        lock.lock()
        readAccounts.append(account)
        if onMainThread { mainThreadReads += 1 }
        let value = storage[account]
        lock.unlock()

        gate.lock()
        while !gateOpen { gate.wait() }
        gate.unlock()
        return value
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
