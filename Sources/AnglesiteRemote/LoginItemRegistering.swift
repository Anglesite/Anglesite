import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Registers (or unregisters) this helper as a login item. Abstracted so tests exercise the
/// decision logic without touching the real login-item database (`SMAppService` has no
/// in-memory test mode and mutates real system state).
public protocol LoginItemRegistering: Sendable {
    /// Current registration status.
    func status() -> LoginItemStatus
    /// Performs the actual registration call, unconditionally — no idempotency check here.
    /// Conformers implement this, not `register()`: the "already enabled" guard lives exactly
    /// once, in `register()`'s default implementation below, so every conformer (including
    /// `FakeLoginItemRegistering`) shares the same idempotency logic instead of each
    /// re-implementing (and potentially diverging from) it.
    func performRegistration() throws
    /// Unregisters the login item.
    func unregister() throws
}

extension LoginItemRegistering {
    /// Registers the login item. Idempotent: calling this when already `.enabled` is a no-op —
    /// `performRegistration()` is only invoked when `status()` isn't already `.enabled`.
    public func register() throws {
        guard status() != .enabled else { return }
        try performRegistration()
    }
}

/// Mirrors `SMAppService.Status`'s cases relevant to this helper's startup decision, without
/// exposing the real enum (keeps this file compilable on non-Darwin per `Package.swift`'s
/// existing platform-gating pattern for Darwin-only targets).
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

#if canImport(ServiceManagement)
/// Production conformer over `SMAppService.agent`.
public struct SMAppServiceLoginItem: LoginItemRegistering {
    private let service: SMAppService

    /// - Parameter plistName: The launchd agent plist name registered under this bundle's
    ///   `Contents/Library/LaunchAgents/` (SMAppService.agent's documented convention).
    public init(plistName: String = "io.dwk.anglesite.remote.plist") {
        self.service = SMAppService.agent(plistName: plistName)
    }

    public func status() -> LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func performRegistration() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}
#endif

/// Test double: in-memory status, no system calls.
public final class FakeLoginItemRegistering: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus
    public private(set) var registerCallCount = 0
    public private(set) var unregisterCallCount = 0

    public init(initialStatus: LoginItemStatus = .notRegistered) {
        self._status = initialStatus
    }

    public func status() -> LoginItemStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public func performRegistration() throws {
        lock.lock(); defer { lock.unlock() }
        registerCallCount += 1
        _status = .enabled
    }

    public func unregister() throws {
        lock.lock(); defer { lock.unlock() }
        unregisterCallCount += 1
        _status = .notRegistered
    }
}
