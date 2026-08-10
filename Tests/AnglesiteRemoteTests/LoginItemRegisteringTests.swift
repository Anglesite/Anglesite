import Testing
@testable import AnglesiteRemote

@Suite struct LoginItemRegisteringTests {
    @Test func registerIsIdempotentWhenAlreadyEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.register()
        #expect(fake.registerCallCount == 1)  // called, but status logic is the real conformer's
        #expect(fake.status() == .enabled)
    }

    @Test func registerTransitionsNotRegisteredToEnabled() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .notRegistered)
        try fake.register()
        #expect(fake.status() == .enabled)
    }

    @Test func unregisterTransitionsToNotRegistered() throws {
        let fake = FakeLoginItemRegistering(initialStatus: .enabled)
        try fake.unregister()
        #expect(fake.status() == .notRegistered)
    }
}
