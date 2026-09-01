import Foundation
import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

/// #1705 — the invisible-publish path's Cloudflare-credential check used to run
/// `SecItemCopyMatching` synchronously on the main actor. Because that call can put up securityd's
/// authorization panel, a site window restoring with a pending invisible publish froze the app's
/// entire UI (zero windows rendered) until the panel was answered.
///
/// These tests pin the two properties the fix has to hold: the store read happens off the main
/// thread, and a read that hasn't answered yet defers the publish instead of waiting on it.
///
/// Both tests need `CLOUDFLARE_API_TOKEN` *unset* — an env token short-circuits the check before
/// the store is ever consulted — so they claim it through `CloudflareAPITokenTestEnvironment` like
/// the other clearers in `DeployModelTests`. `.timeLimit`: same #1349 reasoning as that suite —
/// a wedged test fails loudly instead of hanging the run.
///
/// `.serialized`: the gated test below parks a read on `CloudflareTokenAvailability`'s
/// process-wide serial probe queue, so it must not overlap the other test's probe.
@Suite("DeployModel token probe", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DeployModelTokenProbeTests {
    @Test("an invisible publish never reads the keychain on the main thread")
    func invisiblePublishReadsKeychainOffTheMainThread() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let keychain = RecordingSecretStore()
        let model = DeployModel(logCenter: LogCenter(), keychain: keychain)
        let directory = try makeProbeSiteDirectory()

        let result = await model.deployAutomatically(
            siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [],
            containerControlProvider: { nil })

        guard case .deferred = result else {
            Issue.record("expected .deferred with no credential configured, got \(result)")
            return
        }
        // Not vacuous: the store really was consulted, just not from the main thread.
        let accountsRead = keychain.accountsRead
        #expect(!accountsRead.isEmpty)
        let mainThreadReadCount = keychain.mainThreadReadCount
        #expect(
            mainThreadReadCount == 0,
            "a keychain read on the main thread blocks every window until securityd's authorization panel is answered")
    }

    @Test("an unanswered keychain read defers the invisible publish instead of waiting on it")
    func invisiblePublishDefersWhileTheKeychainIsBusy() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        // Stands in for `SecItemCopyMatching` parked in securityd's authorization panel. The gate
        // must be opened before this test returns — the probe queue is process-wide and serial.
        let keychain = RecordingSecretStore(gated: true)
        defer { keychain.openGate() }
        let model = DeployModel(
            logCenter: LogCenter(), keychain: keychain, tokenProbeTimeout: .milliseconds(50))
        let directory = try makeProbeSiteDirectory()

        let result = await model.deployAutomatically(
            siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [],
            containerControlProvider: { nil })

        guard case .deferred(let reason) = result else {
            Issue.record("expected .deferred while the keychain is busy, got \(result)")
            return
        }
        // Specifically NOT the "not configured" reason: a credential may well be stored, and the
        // queue's pending marker has to survive so the publish happens once the panel is answered.
        #expect(reason.contains("keychain"))
        let phase = model.phase
        #expect(phase == .idle, "a deferred publish must not have started a deploy")
    }

    /// Site directory for these tests. Unique per test, and with no license recorded — the license
    /// gate sits *after* the credential check, so it never fires here.
    private func makeProbeSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployModelTokenProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
