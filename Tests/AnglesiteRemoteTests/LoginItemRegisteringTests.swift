import Testing
@testable import AnglesiteRemote

@Suite struct LoginItemRegisteringTests {
    // Exercises the SHARED idempotency guard in `LoginItemRegistering.register()`'s default
    // implementation (Sources/AnglesiteRemote/LoginItemRegistering.swift) — the same guard
    // `SMAppServiceLoginItem` relies on, since neither conformer implements `register()` itself
    // anymore. `registerCallCount == 0` proves `performRegistration()` was never invoked: the
    // guard short-circuited before reaching the fake's own logic, not just that the fake
    // happened to report `.enabled` afterward.
    @Test func registerIsIdempotentWhenAlreadyEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.register()
        #expect(fake.registerCallCount == 0)
        #expect(fake.status() == .enabled)
    }

    @Test func registerTransitionsNotRegisteredToEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .notRegistered)
        try fake.register()
        #expect(fake.registerCallCount == 1)  // guard did not short-circuit: not already enabled
        #expect(fake.status() == .enabled)
    }

    @Test func unregisterTransitionsToNotRegistered() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.unregister()
        #expect(fake.status() == .notRegistered)
    }
}
