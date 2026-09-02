import Foundation
import Security
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// A `SecretStore` whose interactive and non-interactive faces are distinguishable (#1717). Both
/// faces share one set of counters, so a test can assert *which* face a code path read through.
/// Reads always miss (there is no credential) unless `behavior` says the quiet face must refuse
/// the way a real `KeychainStore` does when the item's ACL would need the user's OK.
private final class InteractionTrackingSecretStore: SecretStore, @unchecked Sendable {
    enum Behavior {
        /// Both faces report "nothing stored".
        case empty
        /// The quiet face throws the status a non-interactive `KeychainStore` read produces for an
        /// item this binary isn't authorized for; the interactive face still reports "nothing".
        case refusesWithoutInteraction
    }

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var interactive = 0
        private var quiet = 0
        func record(interactive isInteractive: Bool) {
            lock.withLock { if isInteractive { interactive += 1 } else { quiet += 1 } }
        }
        var interactiveReads: Int { lock.withLock { interactive } }
        var quietReads: Int { lock.withLock { quiet } }
    }

    private let behavior: Behavior
    private let isInteractive: Bool
    private let counters: Counters

    convenience init(behavior: Behavior = .empty) {
        self.init(behavior: behavior, isInteractive: true, counters: Counters())
    }

    private init(behavior: Behavior, isInteractive: Bool, counters: Counters) {
        self.behavior = behavior
        self.isInteractive = isInteractive
        self.counters = counters
    }

    var interactiveReads: Int { counters.interactiveReads }
    var quietReads: Int { counters.quietReads }

    var withoutUserInteraction: any SecretStore {
        InteractionTrackingSecretStore(behavior: behavior, isInteractive: false, counters: counters)
    }

    func read(account: String) throws -> String? {
        counters.record(interactive: isInteractive)
        if !isInteractive, case .refusesWithoutInteraction = behavior {
            throw KeychainStore.Error.unhandled(errSecAuthFailed)
        }
        return nil
    }

    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}

/// Every test here expects the deploy to defer before a single step runs.
private struct UnreachableDeployExecutor: DeployExecutor {
    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        Issue.record("the deploy must defer before any step runs, but ran \(step)")
        return DeployStepResult(exitCode: 1, output: "")
    }
}

/// The invisible-publish queue (#357) runs `deployAutomatically` after every `Source/` edit, so its
/// credential probe must be a silent local check: a Keychain read that can raise the login-keychain
/// authorization dialog turns every Duplicate/Delete/New Post into a system password prompt
/// (#1717). Foreground `deploy()` is the user's own click and keeps the interactive read.
///
/// The `CLOUDFLARE_API_TOKEN` env var is claimed clear for the duration, same as
/// `DeployModelTests`' own keychain-path tests — `hasUsableToken()` consults it before the store.
@Suite("DeployModel background credential probe (#1717)", .timeLimit(.minutes(1)))
@MainActor
struct DeployModelBackgroundCredentialTests {
    private func makeModel(store: InteractionTrackingSecretStore) -> DeployModel {
        DeployModel(
            command: DeployCommand(
                target: CloudflareDeployTarget(tokenSource: { nil }),
                executor: UnreachableDeployExecutor()),
            logCenter: LogCenter(),
            keychain: store)
    }

    private func makeSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployModelBackgroundCredentialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("deployAutomatically probes credentials through the store's non-interactive face only")
    func automaticDeployNeverReadsInteractively() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let store = InteractionTrackingSecretStore()
        let model = makeModel(store: store)
        let dir = try makeSiteDirectory()

        let result = await model.deployAutomatically(
            siteID: "s", siteDirectory: dir, configDirectory: dir, currentRoutes: [],
            containerControlProvider: { nil })

        #expect(result == .deferred(reason: "Cloudflare credentials are not configured"))
        #expect(store.interactiveReads == 0, "a background publish must never take a read that can prompt")
        #expect(store.quietReads > 0, "the presence check itself still has to happen")
        let tokenPromptPresented = model.tokenPromptPresented
        #expect(!tokenPromptPresented)
    }

    @Test("a Keychain read that would need the user's OK defers the automatic deploy with a permission reason")
    func automaticDeployDefersWhenKeychainNeedsInteraction() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let store = InteractionTrackingSecretStore(behavior: .refusesWithoutInteraction)
        let model = makeModel(store: store)
        let dir = try makeSiteDirectory()

        let result = await model.deployAutomatically(
            siteID: "s", siteDirectory: dir, configDirectory: dir, currentRoutes: [],
            containerControlProvider: { nil })

        guard case .deferred(let reason) = result else {
            Issue.record("expected .deferred, got \(result)")
            return
        }
        // Not "not configured": a credential *is* stored, the app just may not read it silently.
        #expect(reason.localizedCaseInsensitiveContains("keychain"))
        #expect(reason.contains("Publish"), "the reason should point at the foreground action that can grant access")
        #expect(store.interactiveReads == 0)
        let tokenPromptPresented = model.tokenPromptPresented
        #expect(!tokenPromptPresented, "a background attempt never presents the sign-in sheet")
    }

    @Test("a foreground deploy still reads interactively and parks on the sign-in sheet")
    func foregroundDeployReadsInteractively() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let store = InteractionTrackingSecretStore()
        let model = makeModel(store: store)
        let dir = try makeSiteDirectory()

        model.deploy(siteID: "s", siteDirectory: dir, configDirectory: dir, currentRoutes: [])

        #expect(store.interactiveReads > 0, "the user's own click may legitimately prompt")
        #expect(store.quietReads == 0)
        let tokenPromptPresented = model.tokenPromptPresented
        #expect(tokenPromptPresented)
    }
}
