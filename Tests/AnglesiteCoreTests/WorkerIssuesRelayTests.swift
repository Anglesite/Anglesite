import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnglesiteCore
import AnglesiteTestSupport

/// #2095 slice 3: the app side of the Workers Issues relay — `WorkerIssuesRelayClient` against a
/// scripted transport, and `WorkerIssuesReconciler`'s register / renew / revoke decisions.
@Suite("WorkerIssuesRelay") struct WorkerIssuesRelayTests {
    static let siteID = "0f8fad5b-d9cb-469f-a165-70867728950e"
    static let base = URL(string: "https://relay.test")!

    /// Records every request and answers each from `respond`.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var respond: @Sendable (URLRequest) -> (Int, String) = { _ in (500, "") }

        var transport: WorkerIssuesRelayClient.Transport {
            { [self] request in
                lock.lock()
                requests.append(request)
                let respond = self.respond
                lock.unlock()
                let (status, body) = respond(request)
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        var client: WorkerIssuesRelayClient { WorkerIssuesRelayClient(baseURL: WorkerIssuesRelayTests.base, transport: transport) }
    }

    static func registered(secret: String?) -> (Int, String) {
        let secretField = secret.map { #","secret":"\#($0)""# } ?? #","renewed":true"#
        return (200, #"{"siteID":"\#(siteID)","hookPath":"/hook/\#(siteID)","expiresAt":"2026-10-30T12:00:00.000Z"\#(secretField)}"#)
    }

    static let proofKey = String(repeating: "a", count: 64)

    static func secrets(proofKey: String? = WorkerIssuesRelayTests.proofKey, siteSecret: String? = nil) -> InMemorySecretStore {
        let store = InMemorySecretStore()
        if let proofKey { try? store.write(proofKey, account: SecretAccounts.workerIssuesProofKey(siteID: siteID)) }
        if let siteSecret { try? store.write(siteSecret, account: SecretAccounts.workerIssuesWebhookSecret(siteID: siteID)) }
        return store
    }

    // MARK: Client

    @Test("register sends the proof key, hostname and catalog commit, and parses the hook URL and expiry")
    func registerRequestAndResponse() async throws {
        let recorder = Recorder()
        recorder.respond = { _ in Self.registered(secret: "s3cret") }
        let result = await recorder.client.register(
            siteID: Self.siteID.uppercased(), hostname: "blog.dwk.io", catalogCommit: "bd0ad3f",
            proofKey: Self.proofKey, currentSecret: nil)

        let registration = try result.get()
        #expect(registration.secret == "s3cret")
        #expect(registration.hookURL.absoluteString == "https://relay.test/hook/\(Self.siteID)")
        #expect(registration.expiresAt == ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://relay.test/sites")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Site-Secret") == nil)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["siteID": Self.siteID, "hostname": "blog.dwk.io", "catalogCommit": "bd0ad3f", "proofKey": Self.proofKey])
    }

    @Test("register maps relay statuses to failures", arguments: [
        (401, WorkerIssuesRelayClient.Failure.unauthorized),
        (403, .hostnameNotAllowed),
        (422, .domainProofFailed),
        (500, .rejected(status: 500)),
    ])
    func registerFailures(status: Int, expected: WorkerIssuesRelayClient.Failure) async {
        let recorder = Recorder()
        recorder.respond = { _ in (status, "{}") }
        let result = await recorder.client.register(
            siteID: Self.siteID, hostname: "blog.dwk.io", catalogCommit: "c", proofKey: Self.proofKey, currentSecret: nil)
        #expect(result == .failure(expected))
    }

    @Test("a hook path outside /hook/ is rejected rather than trusted")
    func registerRejectsForeignHookPath() async {
        let recorder = Recorder()
        recorder.respond = { _ in (200, #"{"hookPath":"https://evil.test/x","expiresAt":"2026-10-30T12:00:00.000Z","secret":"s"}"#) }
        let result = await recorder.client.register(
            siteID: Self.siteID, hostname: "blog.dwk.io", catalogCommit: "c", proofKey: Self.proofKey, currentSecret: nil)
        #expect(result == .failure(.invalidResponse))
    }

    // MARK: Reconciler

    @Test("wrangler.toml opts in only with an [observability.issues] table")
    func issuesEnabledDetection() {
        #expect(WorkerIssuesReconciler.issuesEnabled(inWranglerToml: "[observability]\nenabled = true\n\n[observability.issues]\nenabled = true\n"))
        #expect(!WorkerIssuesReconciler.issuesEnabled(inWranglerToml: "[observability]\nenabled = true\n"))
        #expect(!WorkerIssuesReconciler.issuesEnabled(inWranglerToml: nil))
    }

    @Test("first registration stores the new secret and asks for the automation step")
    func firstRegistration() async throws {
        let recorder = Recorder()
        recorder.respond = { _ in Self.registered(secret: "s3cret") }
        let secrets = Self.secrets()
        let outcome = await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: URL(string: "https://Blog.dwk.io/"),
            catalogCommit: "bd0ad3f", secrets: secrets, client: recorder.client)

        guard case .registered(_, _, let rotated) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(rotated)
        #expect(try secrets.read(account: SecretAccounts.workerIssuesWebhookSecret(siteID: Self.siteID)) == "s3cret")
        let body = try JSONSerialization.jsonObject(with: try #require(recorder.requests.first?.httpBody)) as? [String: String]
        #expect(body?["hostname"] == "blog.dwk.io")
    }

    @Test("renewal presents the current secret and keeps it")
    func renewal() async throws {
        let recorder = Recorder()
        recorder.respond = { _ in Self.registered(secret: nil) }
        let secrets = Self.secrets(siteSecret: "existing")
        let outcome = await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: URL(string: "https://blog.dwk.io"),
            secrets: secrets, client: recorder.client)

        guard case .registered(_, _, let rotated) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(!rotated)
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "X-Site-Secret") == "existing")
        #expect(try secrets.read(account: SecretAccounts.workerIssuesWebhookSecret(siteID: Self.siteID)) == "existing")
    }

    @Test("no proof key or no hostname means no request at all")
    func preconditions() async {
        let recorder = Recorder()
        #expect(await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: URL(string: "https://blog.dwk.io"),
            secrets: Self.secrets(proofKey: nil), client: recorder.client) == .proofNotPublished)
        #expect(await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: nil,
            secrets: Self.secrets(), client: recorder.client) == .noHostname)
        #expect(recorder.requests.isEmpty)
    }

    @Test("turning Issues off revokes with the site's secret and forgets it — even if the relay is down")
    func revocation() async throws {
        for status in [204, 500] {
            let recorder = Recorder()
            recorder.respond = { _ in (status, "") }
            let secrets = Self.secrets(siteSecret: "existing")
            let outcome = await WorkerIssuesReconciler.reconcile(
                siteID: Self.siteID, issuesEnabled: false, siteURL: nil, secrets: secrets, client: recorder.client)
            #expect(outcome == .revoked)
            let request = try #require(recorder.requests.first)
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.absoluteString == "https://relay.test/sites/\(Self.siteID)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer existing")
            #expect(try secrets.read(account: SecretAccounts.workerIssuesWebhookSecret(siteID: Self.siteID)) == nil)
            #expect(try secrets.read(account: SecretAccounts.workerIssuesProofKey(siteID: Self.siteID)) == nil)
        }
    }

    // MARK: Domain proof (slice 5)

    @Test("the published proof matches the relay's pinned cross-language vector")
    func proofVector() {
        // Workers/issues-relay/test/proof.test.ts pins the same value for the same inputs.
        #expect(WorkerIssuesProof.publishedValue(siteID: Self.siteID.uppercased(), key: Self.proofKey)
            == "112a82a7c4ce77b6f898cef66ab3c08c1fd73f010d256f609f59057595bd535b")
    }

    @Test("a publish creates the proof key once, then serves the same value; off serves nothing")
    func valueForPublish() throws {
        let secrets = Self.secrets(proofKey: nil)
        let first = try #require(WorkerIssuesProof.valueForPublish(siteID: Self.siteID, enabled: true, secrets: secrets))
        let key = try #require(try secrets.read(account: SecretAccounts.workerIssuesProofKey(siteID: Self.siteID)))
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit))
        #expect(first == WorkerIssuesProof.publishedValue(siteID: Self.siteID, key: key))
        #expect(WorkerIssuesProof.valueForPublish(siteID: Self.siteID, enabled: true, secrets: secrets) == first)
        #expect(WorkerIssuesProof.valueForPublish(siteID: Self.siteID, enabled: false, secrets: secrets) == nil)
    }

    @Test("a proof the relay can't see yet is retried after a pause, then succeeds")
    func proofRetry() async {
        let recorder = Recorder()
        let attempts = Counter()
        recorder.respond = { _ in attempts.increment() < 2 ? (422, "{}") : Self.registered(secret: "s3cret") }
        let slept = Counter()
        let outcome = await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: URL(string: "https://blog.dwk.io"),
            secrets: Self.secrets(), client: recorder.client, sleep: { _ in slept.increment() })
        guard case .registered = outcome else { Issue.record("got \(outcome)"); return }
        #expect(recorder.requests.count == 3)
        #expect(slept.value == 2)
    }

    @Test("a proof that never verifies gives up after the retries")
    func proofRetryGivesUp() async {
        let recorder = Recorder()
        recorder.respond = { _ in (422, "{}") }
        let outcome = await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: true, siteURL: URL(string: "https://blog.dwk.io"),
            secrets: Self.secrets(), client: recorder.client, sleep: { _ in })
        #expect(outcome == .failed(.domainProofFailed))
        #expect(recorder.requests.count == 1 + WorkerIssuesReconciler.proofRetryDelays.count)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        @discardableResult func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            let before = count
            count += 1
            return before
        }
    }

    @Test("off and never registered is a no-op")
    func inactive() async {
        let recorder = Recorder()
        #expect(await WorkerIssuesReconciler.reconcile(
            siteID: Self.siteID, issuesEnabled: false, siteURL: nil, secrets: Self.secrets(), client: recorder.client) == .inactive)
        #expect(recorder.requests.isEmpty)
    }

    @Test("apply: a rotated secret resets the automation step; renewal keeps it; revocation clears")
    func applyOutcome() {
        let hook = URL(string: "https://relay.test/hook/x")!
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let confirmed = WorkerIssuesRelayState(hookURL: hook, expiresAt: Date(timeIntervalSince1970: 0), automationConfirmed: true)

        #expect(WorkerIssuesReconciler.apply(.registered(hookURL: hook, expiresAt: expiry, secretRotated: false), to: confirmed)
            == WorkerIssuesRelayState(hookURL: hook, expiresAt: expiry, automationConfirmed: true))
        #expect(WorkerIssuesReconciler.apply(.registered(hookURL: hook, expiresAt: expiry, secretRotated: true), to: confirmed)?
            .automationConfirmed == false)
        #expect(WorkerIssuesReconciler.apply(.revoked, to: confirmed) == nil)
        #expect(WorkerIssuesReconciler.apply(.failed(.network), to: confirmed) == confirmed)
    }

    @Test("log lines never carry a secret")
    func logMessagesAreSecretFree() {
        let hook = URL(string: "https://relay.test/hook/x")!
        let outcomes: [WorkerIssuesReconciler.Outcome] = [
            .proofNotPublished, .noHostname, .revoked, .secretStoreUnavailable, .failed(.unauthorized),
            .registered(hookURL: hook, expiresAt: Date(), secretRotated: true),
        ]
        for outcome in outcomes {
            let message = WorkerIssuesReconciler.logMessage(for: outcome) ?? ""
            #expect(!message.contains("s3cret") && !message.contains(Self.proofKey))
        }
        #expect(WorkerIssuesReconciler.logMessage(for: .inactive) == nil)
    }
}
