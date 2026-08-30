import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for the `GitHubPagesDeployTarget` conformer (#1015 slice 2b) — the token-gate in
/// `authorize`, repo provisioning + persistence in `publish`, and the executor
/// environment/step-result contract, exercised directly against the target (not through
/// `DeployCommand`) so a test can assert exactly which GitHub API calls did or didn't happen.
struct GitHubPagesDeployTargetTests {
    /// A fresh temp site directory per test, so `DomainConfigStore` reads/writes don't collide
    /// across tests and each test starts with no `anglesite.json`.
    private func makeSiteDirectory() throws -> URL {
        let siteDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubPagesDeployTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDirectory, withIntermediateDirectories: true)
        return siteDirectory
    }

    // MARK: Fake executor

    /// A minimal `DeployExecutor` recording every call's step/environment, returning a canned
    /// result for `.githubPagesPublish`.
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        struct Call: Sendable { let step: DeployStep; let environment: [String: String] }
        private let lock = NSLock()
        private var result = DeployStepResult(exitCode: 0, output: "")
        private(set) var calls: [Call] = []

        @discardableResult
        func returning(exitCode: Int32?, output: String = "") -> FakeExecutor {
            lock.lock(); result = DeployStepResult(exitCode: exitCode, output: output); lock.unlock()
            return self
        }

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.lock()
            calls.append(Call(step: step, environment: environment))
            let toReturn = result
            lock.unlock()
            return toReturn
        }
    }

    /// A fake `GitHubAPITokenVerifier.Transport` that records every request path/method and
    /// answers `createRepo`/`enablePages` with canned success bodies.
    private final class FakeGitHubTransport: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requestedPaths: [(method: String, path: String)] = []
        var createRepoOwner = "acme"
        var createRepoName = "site-pages"

        func transport() -> GitHubAPITokenVerifier.Transport {
            { [self] request in
                lock.lock()
                requestedPaths.append((request.httpMethod ?? "", request.url?.path ?? ""))
                lock.unlock()
                let path = request.url?.path ?? ""
                if path == "/user/repos" {
                    let json = #"{"name":"\#(createRepoName)","html_url":"https://github.com/\#(createRepoOwner)/\#(createRepoName)","owner":{"login":"\#(createRepoOwner)"}}"#
                    let http = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                    return (Data(json.utf8), http)
                }
                // enablePages: POST /repos/{owner}/{repo}/pages
                let http = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), http)
            }
        }

        func calls(toPathSuffix suffix: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return requestedPaths.filter { $0.path.hasSuffix(suffix) }.count
        }
    }

    // MARK: authorize

    @Test("authorize blocks when the token is missing")
    func authorizeBlocksOnMissingToken() async {
        let target = GitHubPagesDeployTarget(tokenSource: { nil })
        let outcome = await target.authorize(siteDirectory: URL(fileURLWithPath: "/tmp"))
        guard case .blocked(.failed) = outcome else {
            Issue.record("expected .blocked(.failed), got \(outcome)"); return
        }
    }

    @Test("authorize blocks when the token is empty")
    func authorizeBlocksOnEmptyToken() async {
        let target = GitHubPagesDeployTarget(tokenSource: { "" })
        let outcome = await target.authorize(siteDirectory: URL(fileURLWithPath: "/tmp"))
        guard case .blocked(.failed) = outcome else {
            Issue.record("expected .blocked(.failed), got \(outcome)"); return
        }
    }

    @Test("authorize is ready with a valid token")
    func authorizeReadyWithValidToken() async {
        let target = GitHubPagesDeployTarget(tokenSource: { "tok" })
        let outcome = await target.authorize(siteDirectory: URL(fileURLWithPath: "/tmp"))
        guard case .ready(let credential) = outcome else {
            Issue.record("expected .ready, got \(outcome)"); return
        }
        #expect(credential == "tok")
    }

    // MARK: publish — repo provisioning

    @Test("publish with a pre-configured githubPages section makes no createRepo/enablePages call")
    func publishReusesDeclaredRepo() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        DomainConfigStore.update(sourceDirectory: siteDirectory) {
            $0.githubPages = DomainConfig.GitHubPages(owner: "declared-owner", repo: "declared-repo")
        }
        let transport = FakeGitHubTransport()
        let target = GitHubPagesDeployTarget(tokenSource: { "tok" }, client: HTTPGitHubClient(transport: transport.transport()))
        let executor = FakeExecutor().returning(exitCode: 0)

        let context = DeployTargetContext(
            siteID: "site-id", siteDirectory: siteDirectory, configDirectory: nil, currentRoutes: [],
            credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
        let result = await target.publish(context: context)

        #expect(transport.calls(toPathSuffix: "/user/repos") == 0)
        #expect(transport.calls(toPathSuffix: "/pages") == 0)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url == URL(string: "https://declared-owner.github.io/declared-repo/"))
    }

    @Test("publish without a declared repo creates it, enables Pages once, and persists owner/repo")
    func publishProvisionsAndPersists() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let transport = FakeGitHubTransport()
        transport.createRepoOwner = "fresh-owner"
        transport.createRepoName = "fresh-repo"
        let target = GitHubPagesDeployTarget(tokenSource: { "tok" }, client: HTTPGitHubClient(transport: transport.transport()))
        let executor = FakeExecutor().returning(exitCode: 0)

        let context = DeployTargetContext(
            siteID: "site-id", siteDirectory: siteDirectory, configDirectory: nil, currentRoutes: [],
            credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
        let result = await target.publish(context: context)

        #expect(transport.calls(toPathSuffix: "/user/repos") == 1)
        #expect(transport.calls(toPathSuffix: "/pages") == 1)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url == URL(string: "https://fresh-owner.github.io/fresh-repo/"))

        let persisted = try DomainConfigStore(sourceDirectory: siteDirectory).load().githubPages
        #expect(persisted?.owner == "fresh-owner")
        #expect(persisted?.repo == "fresh-repo")
    }

    // MARK: publish — environment contract

    @Test("the executor receives GITHUB_PAGES_TOKEN for .githubPagesPublish and no other secret leaks in")
    func environmentContract() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        DomainConfigStore.update(sourceDirectory: siteDirectory) {
            $0.githubPages = DomainConfig.GitHubPages(owner: "o", repo: "r")
        }
        let transport = FakeGitHubTransport()
        let target = GitHubPagesDeployTarget(tokenSource: { "secret-tok" }, client: HTTPGitHubClient(transport: transport.transport()))
        let executor = FakeExecutor().returning(exitCode: 0)

        let context = DeployTargetContext(
            siteID: "site-id", siteDirectory: siteDirectory, configDirectory: nil, currentRoutes: [],
            credential: "secret-tok", baseEnvironment: ["PATH": "/usr/bin"], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
        _ = await target.publish(context: context)

        #expect(executor.calls.count == 1)
        let call = try #require(executor.calls.first)
        #expect(call.step.isGithubPagesPublish)
        #expect(call.environment["GITHUB_PAGES_TOKEN"] == "secret-tok")
        #expect(call.environment["PATH"] == "/usr/bin")
        #expect(call.environment.count == 2)
    }

    // MARK: publish — failure mapping

    @Test("a non-zero .githubPagesPublish exit maps to .failed with that exit code")
    func nonZeroExitMapsToFailed() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        DomainConfigStore.update(sourceDirectory: siteDirectory) {
            $0.githubPages = DomainConfig.GitHubPages(owner: "o", repo: "r")
        }
        let transport = FakeGitHubTransport()
        let target = GitHubPagesDeployTarget(tokenSource: { "tok" }, client: HTTPGitHubClient(transport: transport.transport()))
        let executor = FakeExecutor().returning(exitCode: 17, output: "push rejected")

        let context = DeployTargetContext(
            siteID: "site-id", siteDirectory: siteDirectory, configDirectory: nil, currentRoutes: [],
            credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: nil, onMarkdownForAgents: nil, onProgress: nil)
        let result = await target.publish(context: context)

        guard case .failed(_, let exitCode) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(exitCode == 17)
    }

    // MARK: publish — no domain-attach/markdown-for-agents concept

    @Test("onDomainAttach and onMarkdownForAgents are never invoked by this target")
    func neverFiresCloudflareOnlyObservers() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        DomainConfigStore.update(sourceDirectory: siteDirectory) {
            $0.githubPages = DomainConfig.GitHubPages(owner: "o", repo: "r")
        }
        let transport = FakeGitHubTransport()
        let target = GitHubPagesDeployTarget(tokenSource: { "tok" }, client: HTTPGitHubClient(transport: transport.transport()))
        let executor = FakeExecutor().returning(exitCode: 0)

        final class Flags: @unchecked Sendable {
            var domainAttachFired = false
            var markdownForAgentsFired = false
        }
        let flags = Flags()

        let context = DeployTargetContext(
            siteID: "site-id", siteDirectory: siteDirectory, configDirectory: nil, currentRoutes: [],
            credential: "tok", baseEnvironment: [:], executor: executor,
            onDomainAttach: { _ in flags.domainAttachFired = true },
            onMarkdownForAgents: { _ in flags.markdownForAgentsFired = true },
            onProgress: nil)
        _ = await target.publish(context: context)

        #expect(!flags.domainAttachFired)
        #expect(!flags.markdownForAgentsFired)
    }
}

private extension DeployStep {
    var isGithubPagesPublish: Bool {
        if case .githubPagesPublish = self { return true }
        return false
    }
}
