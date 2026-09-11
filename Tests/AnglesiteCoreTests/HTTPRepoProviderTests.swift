#if canImport(Darwin)
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

/// `HTTPRepoProvider` replaces `GHRepoProvider` on Darwin (#654): REST API repo creation
/// (`HTTPGitHubClient`, transport mocked here) + in-process SwiftGit2 `addRemote`/`push` (real,
/// against a local bare repo standing in for GitHub — `createRepo`'s transport being mocked means
/// there's no real GitHub repo to push into, so `remoteURL` is overridden to point at the fixture
/// instead of the real `https://github.com/...` URL production always uses).
///
/// .serialized: libgit2 isn't safe for uncoordinated concurrent use (see the fork's specs, and
/// `InProcessGitTests`, which follows the same fixture style this file mirrors).
@Suite("HTTPRepoProvider", .serialized) struct HTTPRepoProviderTests {

    @discardableResult
    private func git(_ arguments: [String], in dir: URL) async throws -> String {
        let result = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            currentDirectoryURL: dir
        )
        guard result.exitCode == 0 else {
            Issue.record("fixture git \(arguments.joined(separator: " ")) exited \(result.exitCode): \(result.stderr)")
            throw FixtureError.gitFailed
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum FixtureError: Error { case gitFailed }

    /// A repo on `main` with local identity configured and one commit — mirrors `ensureCommittable`
    /// having already run by the time `createAndPush` is called in the real `publish` flow.
    private func makeRepo() async throws -> URL {
        let dir = try makeTempDir(prefix: "http-repo-provider-work")
        try await git(["init", "-b", "main"], in: dir)
        try await git(["config", "user.name", "Test"], in: dir)
        try await git(["config", "user.email", "test@example.com"], in: dir)
        try "hello".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"], in: dir)
        try await git(["commit", "-m", "first"], in: dir)
        return dir
    }

    /// Empty bare repo standing in for the "GitHub repo" `createRepo`'s mocked transport reports
    /// as created — `addRemote`/`push` target this for real.
    private func makeBareRemote() async throws -> URL {
        let dir = try makeTempDir(prefix: "http-repo-provider-origin")
        try await git(["init", "--bare"], in: dir)
        return dir
    }

    private func transport(status: Int, json: String) -> GitHubAPITokenVerifier.Transport {
        { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), http)
        }
    }

    @Test("isAuthenticated reflects whether a token is stored")
    func isAuthenticatedReflectsToken() async {
        let withToken = HTTPRepoProvider(tokenProvider: { "tok" })
        let withoutToken = HTTPRepoProvider(tokenProvider: { nil })
        #expect(await withToken.isAuthenticated() == true)
        #expect(await withoutToken.isAuthenticated() == false)
    }

    @Test("createAndPush creates the repo, wires origin, and pushes the current branch")
    func createAndPushSucceeds() async throws {
        let repoDir = try await makeRepo()
        let remote = try await makeBareRemote()
        let localHEAD = try await git(["rev-parse", "HEAD"], in: repoDir)

        let client = HTTPGitHubClient(transport: transport(
            status: 201,
            json: #"{"name":"site","html_url":"https://github.com/acme/site","owner":{"login":"acme"}}"#))
        let provider = HTTPRepoProvider(
            client: client,
            tokenProvider: { "tok" },
            remoteURL: { _ in remote.absoluteString }
        )

        let created = try await provider.createAndPush(name: "site", isPrivate: true, source: repoDir)
        #expect(created.owner == "acme")
        #expect(created.name == "site")
        #expect(created.url == URL(string: "https://github.com/acme/site"))

        // The push actually landed: the bare "remote" now has the same commit as local HEAD.
        let remoteHEAD = try await git(["rev-parse", "main"], in: remote)
        #expect(remoteHEAD == localHEAD)

        // origin is wired in the local repo too — remote(of:) (the SwiftGit2 preflight read) can
        // find it on a subsequent publish/open.
        let originURL = try await git(["remote", "get-url", "origin"], in: repoDir)
        #expect(originURL == remote.absoluteString)
    }

    @Test("createAndPush throws before hitting the network when no token is stored")
    func createAndPushRequiresToken() async throws {
        let repoDir = try await makeRepo()
        let provider = HTTPRepoProvider(tokenProvider: { nil })
        await #expect(throws: RepoBootstrapError.self) {
            _ = try await provider.createAndPush(name: "site", isPrivate: true, source: repoDir)
        }
    }

    @Test("a name-conflict from the API surfaces as a user-facing RepoBootstrapError")
    func createAndPushMapsNameConflict() async throws {
        let repoDir = try await makeRepo()
        let client = HTTPGitHubClient(transport: transport(
            status: 422,
            json: #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#))
        let provider = HTTPRepoProvider(client: client, tokenProvider: { "tok" })
        do {
            _ = try await provider.createAndPush(name: "site", isPrivate: true, source: repoDir)
            Issue.record("expected a throw")
        } catch let error as RepoBootstrapError {
            #expect(error.reason.contains("already exists"))
        }
    }

    @Test("a repo created but not pushable (source isn't a git repo) still names the created URL")
    func createAndPushSurfacesCreatedURLWhenSourceIsNotARepo() async throws {
        // The remote repository now genuinely exists on GitHub even though the local push can't
        // happen — the failure message must say so, not read like nothing happened.
        let notARepo = try makeTempDir(prefix: "http-repo-provider-not-a-repo")
        let client = HTTPGitHubClient(transport: transport(
            status: 201,
            json: #"{"name":"site","html_url":"https://github.com/acme/site","owner":{"login":"acme"}}"#))
        let provider = HTTPRepoProvider(client: client, tokenProvider: { "tok" })
        do {
            _ = try await provider.createAndPush(name: "site", isPrivate: true, source: notARepo)
            Issue.record("expected a throw")
        } catch let error as RepoBootstrapError {
            #expect(error.reason.contains("https://github.com/acme/site"))
        }
    }
}
#endif
