// Exercises `KeychainStore`'s non-interactive mode (#1717); compiles out with the Security
// framework off-Darwin, like `KeychainStoreTests`.
#if canImport(Security)
import Foundation
import Security
import XCTest
@testable import AnglesiteCore

/// The login-keychain authorization dialog ("Anglesite wants to use your confidential
/// information…") is raised by `SecItemCopyMatching` whenever the calling binary isn't on an
/// item's ACL. Background work must never raise it (#1717), so `KeychainStore` offers a
/// `withoutUserInteraction` face whose reads fail fast instead. These tests pin that contract.
///
/// Same environment handling as `KeychainStoreTests`: a unique service per test, and a clean
/// `XCTSkip` when the keychain isn't reachable at all.
final class KeychainStoreUserInteractionTests: XCTestCase {
    private var service = ""
    private var store: KeychainStore!

    override func setUp() async throws {
        service = "io.dwk.anglesite.tests." + UUID().uuidString
        store = KeychainStore(service: service)
        do {
            try store.write("probe", account: "__probe__")
            try store.delete(account: "__probe__")
        } catch KeychainStore.Error.unhandled(let status) {
            throw XCTSkip("keychain not reachable in this environment (OSStatus \(status))")
        }
    }

    override func tearDown() async throws {
        try? store.delete(account: "alpha")
        Self.deleteForeignItem(service: service, account: "foreign")
    }

    // MARK: Mode plumbing

    func testDefaultStoreAllowsUserInteraction() {
        XCTAssertTrue(store.allowsUserInteraction)
        XCTAssertTrue(KeychainStore().allowsUserInteraction)
    }

    /// The derived store addresses exactly the same items: same service, same access group, same
    /// query shape. The mode is a call-time policy, never an attribute of the stored item.
    func testWithoutUserInteractionPreservesServiceAccessGroupAndQuery() {
        let scoped = KeychainStore(service: service, accessGroup: "TESTPREFIX.io.dwk.anglesite.shared")
        guard let quiet = scoped.withoutUserInteraction as? KeychainStore else {
            return XCTFail("expected a KeychainStore, got \(type(of: scoped.withoutUserInteraction))")
        }
        XCTAssertEqual(quiet.service, service)
        XCTAssertEqual(quiet.accessGroup, scoped.accessGroup)
        XCTAssertFalse(quiet.allowsUserInteraction)
        XCTAssertEqual(
            quiet.baseQuery(account: "alpha").keys.sorted(),
            scoped.baseQuery(account: "alpha").keys.sorted())
    }

    /// Through the `SecretStore` existential (how `DeployModel` holds its store) the same face is
    /// reachable, and it's still a `KeychainStore` — not the protocol's identity default.
    func testWithoutUserInteractionIsReachableThroughTheProtocol() {
        let erased: any SecretStore = store
        guard let quiet = erased.withoutUserInteraction as? KeychainStore else {
            return XCTFail("expected a KeychainStore, got \(type(of: erased.withoutUserInteraction))")
        }
        XCTAssertFalse(quiet.allowsUserInteraction)
        XCTAssertEqual(quiet.service, service)
    }

    // MARK: Behavior

    /// Items this binary wrote are on the ACL already, so the quiet face reads them exactly like
    /// the default one — misses included. Nothing about "no prompting" may cost a legitimate read.
    func testWithoutUserInteractionReadsOurOwnItems() throws {
        try store.write("mine", account: "alpha")
        XCTAssertEqual(try store.withoutUserInteraction.read(account: "alpha"), "mine")
        XCTAssertNil(try store.withoutUserInteraction.read(account: "never-written"))
    }

    /// The property this mode exists for: an item this binary is *not* on the ACL of — created by
    /// `/usr/bin/security`, so the ACL trusts that tool and nothing else — must be refused
    /// immediately rather than blocking on the authorization dialog. The read runs on its own thread
    /// with a deadline so a regression fails the test instead of hanging the whole run on a modal
    /// prompt (the interactive default would block there until someone clicked).
    func testWithoutUserInteractionRefusesInsteadOfPromptingForForeignItem() async throws {
        try Self.createForeignItem(service: service, account: "foreign")
        let quiet = store.withoutUserInteraction
        let finished = expectation(description: "read returned without prompting")
        let outcome = OutcomeBox()
        Thread.detachNewThread {
            outcome.set(Result { try quiet.read(account: "foreign") })
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)

        guard let result = outcome.get() else {
            return XCTFail("the read is still blocked — a keychain authorization prompt was shown")
        }
        switch result {
        case .success(let value):
            XCTFail("expected the read to be refused, got \(value == nil ? "nil" : "a value")")
        case .failure(let error):
            guard let keychainError = error as? KeychainStore.Error else {
                return XCTFail("expected KeychainStore.Error, got \(error)")
            }
            XCTAssertTrue(keychainError.requiresUserInteraction, "unexpected error \(keychainError)")
        }
    }

    /// `requiresUserInteraction` is the exact status set the non-interactive read (and a user's
    /// "Deny" on the interactive one) produce — nothing else, so a genuinely broken keychain isn't
    /// misreported as "just needs permission".
    func testRequiresUserInteractionCoversOnlyAuthorizationStatuses() {
        XCTAssertTrue(KeychainStore.Error.unhandled(errSecAuthFailed).requiresUserInteraction)
        XCTAssertTrue(KeychainStore.Error.unhandled(errSecInteractionNotAllowed).requiresUserInteraction)
        XCTAssertTrue(KeychainStore.Error.unhandled(errSecUserCanceled).requiresUserInteraction)
        XCTAssertFalse(KeychainStore.Error.unhandled(errSecMissingEntitlement).requiresUserInteraction)
        XCTAssertFalse(KeychainStore.Error.unhandled(errSecParam).requiresUserInteraction)
        XCTAssertFalse(KeychainStore.Error.invalidUTF8.requiresUserInteraction)
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

    /// Creates a generic-password item whose ACL trusts `/usr/bin/security` only. Skips the test
    /// when the tool can't write to the default keychain (some CI images).
    private static func createForeignItem(service: String, account: String) throws {
        let status = runSecurity(["add-generic-password", "-s", service, "-a", account, "-w", "foreign-secret", "-U"])
        if status != 0 {
            throw XCTSkip("/usr/bin/security couldn't create a keychain item here (exit \(status))")
        }
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
