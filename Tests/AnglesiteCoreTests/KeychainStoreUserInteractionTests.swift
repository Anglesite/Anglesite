// Exercises `KeychainStore`'s non-interactive mode (#1717); compiles out with the Security
// framework off-Darwin, like `KeychainStoreTests`.
#if canImport(Security)
import Testing
import Foundation
import Security
import AnglesiteTestSupport
@testable import AnglesiteCore

/// The login-keychain authorization dialog ("Anglesite wants to use your confidential
/// information…") is raised by `SecItemCopyMatching` whenever the calling binary isn't on an
/// item's ACL. Background work must never raise it (#1717), so `KeychainStore` offers a
/// `withoutUserInteraction` face whose reads fail fast instead. These tests pin that contract.
///
/// Kept at file scope rather than as a static member of `KeychainStoreUserInteractionTests`
/// itself — referencing a type's own static from its `@Suite` trait creates a circular
/// macro-expansion error.
private let keychainUserInteractionTestsKeychainReachable: Bool = {
    let probe = KeychainStore(service: "io.dwk.anglesite.tests.probe-\(UUID().uuidString)")
    do {
        try probe.write("probe", account: "__probe__")
        try probe.delete(account: "__probe__")
        return true
    } catch {
        return false
    }
}()

/// Same environment handling as `KeychainStoreTests`: a unique service per test, and a clean
/// suite skip (via `.enabled(if:)`) when the keychain isn't reachable at all.
@Suite(.enabled(if: keychainUserInteractionTestsKeychainReachable, "keychain not reachable in this environment"))
final class KeychainStoreUserInteractionTests {
    private let service: String
    private let store: KeychainStore

    /// Whether `/usr/bin/security` can create a keychain item here — some CI images can't.
    /// Evaluated once by creating and immediately deleting a scratch item.
    static let securityToolAvailable: Bool = {
        let probeService = "io.dwk.anglesite.tests.security-probe-\(UUID().uuidString)"
        let status = runSecurity(["add-generic-password", "-s", probeService, "-a", "__probe__", "-w", "probe", "-U"])
        _ = runSecurity(["delete-generic-password", "-s", probeService, "-a", "__probe__"])
        return status == 0
    }()

    init() {
        service = "io.dwk.anglesite.tests." + UUID().uuidString
        store = KeychainStore(service: service)
    }

    deinit {
        try? store.delete(account: "alpha")
        Self.deleteForeignItem(service: service, account: "foreign")
    }

    // MARK: Mode plumbing

    @Test("the default store allows user interaction")
    func defaultStoreAllowsUserInteraction() {
        #expect(store.allowsUserInteraction)
        #expect(KeychainStore().allowsUserInteraction)
    }

    /// The derived store addresses exactly the same items: same service, same access group, same
    /// query shape. The mode is a call-time policy, never an attribute of the stored item.
    @Test("withoutUserInteraction preserves the service, access group, and query")
    func withoutUserInteractionPreservesServiceAccessGroupAndQuery() throws {
        let scoped = KeychainStore(service: service, accessGroup: "TESTPREFIX.io.dwk.anglesite.shared")
        guard let quiet = scoped.withoutUserInteraction as? KeychainStore else {
            Issue.record("expected a KeychainStore, got \(type(of: scoped.withoutUserInteraction))")
            return
        }
        #expect(quiet.service == service)
        #expect(quiet.accessGroup == scoped.accessGroup)
        #expect(!quiet.allowsUserInteraction)
        #expect(
            quiet.baseQuery(account: "alpha").keys.sorted() ==
            scoped.baseQuery(account: "alpha").keys.sorted())
    }

    /// Through the `SecretStore` existential (how `DeployModel` holds its store) the same face is
    /// reachable, and it's still a `KeychainStore` — not the protocol's identity default.
    @Test("withoutUserInteraction is reachable through the protocol")
    func withoutUserInteractionIsReachableThroughTheProtocol() {
        let erased: any SecretStore = store
        guard let quiet = erased.withoutUserInteraction as? KeychainStore else {
            Issue.record("expected a KeychainStore, got \(type(of: erased.withoutUserInteraction))")
            return
        }
        #expect(!quiet.allowsUserInteraction)
        #expect(quiet.service == service)
    }

    // MARK: Behavior

    /// Items this binary wrote are on the ACL already, so the quiet face reads them exactly like
    /// the default one — misses included. Nothing about "no prompting" may cost a legitimate read.
    @Test("withoutUserInteraction reads our own items")
    func withoutUserInteractionReadsOurOwnItems() throws {
        try store.write("mine", account: "alpha")
        #expect(try store.withoutUserInteraction.read(account: "alpha") == "mine")
        #expect(try store.withoutUserInteraction.read(account: "never-written") == nil)
    }

    /// The property this mode exists for: an item this binary is *not* on the ACL of — created by
    /// `/usr/bin/security`, so the ACL trusts that tool and nothing else — must be refused
    /// immediately rather than blocking on the authorization dialog. The read runs on its own thread
    /// with a deadline so a regression fails the test instead of hanging the whole run on a modal
    /// prompt (the interactive default would block there until someone clicked).
    @Test(
        "withoutUserInteraction refuses instead of prompting for a foreign item",
        .enabled(if: KeychainStoreUserInteractionTests.securityToolAvailable,
                  "/usr/bin/security couldn't create a keychain item here")
    )
    func withoutUserInteractionRefusesInsteadOfPromptingForForeignItem() async throws {
        try Self.createForeignItem(service: service, account: "foreign")
        let quiet = store.withoutUserInteraction
        let outcome = OutcomeBox()
        Thread.detachNewThread {
            outcome.set(Result { try quiet.read(account: "foreign") })
        }
        try await waitUntil("read returned without prompting", timeout: .seconds(5)) {
            outcome.get() != nil
        }

        guard let result = outcome.get() else {
            Issue.record("the read is still blocked — a keychain authorization prompt was shown")
            return
        }
        switch result {
        case .success(let value):
            Issue.record("expected the read to be refused, got \(value == nil ? "nil" : "a value")")
        case .failure(let error):
            guard let keychainError = error as? KeychainStore.Error else {
                Issue.record("expected KeychainStore.Error, got \(error)")
                return
            }
            #expect(keychainError.requiresUserInteraction, "unexpected error \(keychainError)")
        }
    }

    /// `requiresUserInteraction` is the exact status set the non-interactive read (and a user's
    /// "Deny" on the interactive one) produce — nothing else, so a genuinely broken keychain isn't
    /// misreported as "just needs permission".
    @Test("requiresUserInteraction covers only authorization statuses")
    func requiresUserInteractionCoversOnlyAuthorizationStatuses() {
        #expect(KeychainStore.Error.unhandled(errSecAuthFailed).requiresUserInteraction)
        #expect(KeychainStore.Error.unhandled(errSecInteractionNotAllowed).requiresUserInteraction)
        #expect(KeychainStore.Error.unhandled(errSecUserCanceled).requiresUserInteraction)
        #expect(!KeychainStore.Error.unhandled(errSecMissingEntitlement).requiresUserInteraction)
        #expect(!KeychainStore.Error.unhandled(errSecParam).requiresUserInteraction)
        #expect(!KeychainStore.Error.invalidUTF8.requiresUserInteraction)
    }

    // MARK: Helpers

    /// Cross-thread hand-off for the timed read. Locked rather than `nonisolated(unsafe)` so the
    /// ThreadSanitizer CI lane sees a clean exchange.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<String?, Error>?
        func set(_ newValue: Result<String?, Error>) { lock.withLock { value = newValue } }
        func get() -> Result<String?, Error>? { lock.withLock { value } }
    }

    /// Creates a generic-password item whose ACL trusts `/usr/bin/security` only.
    private static func createForeignItem(service: String, account: String) throws {
        _ = runSecurity(["add-generic-password", "-s", service, "-a", account, "-w", "foreign-secret", "-U"])
    }

    private static func deleteForeignItem(service: String, account: String) {
        _ = runSecurity(["delete-generic-password", "-s", service, "-a", account])
    }

    /// Direct `Process` use is fine in a test; the app-side rule (`ProcessSupervisor` only) is about
    /// keeping subprocess output in the debug pane, which doesn't apply to a test fixture.
    private static func runSecurity(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
