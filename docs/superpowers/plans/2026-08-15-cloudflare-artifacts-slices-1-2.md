# Cloudflare Artifacts Slices 1–2 Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the beta-independent half of #1266 — a host-agnostic `RemoteRepo` (slice 1) and a mockable Cloudflare Artifacts API client with a strict availability probe (slice 2).

**Architecture:** Slice 1 replaces `RemoteRepo.parse`'s github.com-only guard with a `RepoHost` enum that owns host matching and browse-URL derivation. Slice 2 adds `HTTPArtifactsClient` behind the existing `CloudflareTransport` seam, mirroring `HTTPGitHubClient`/`CloudflareCapabilityProber` patterns. Every Artifacts API assumption (host name, endpoint path, response shape) lives in exactly one constant/type so beta verification is a one-file update.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), AnglesiteCore SwiftPM target only. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-15-cloudflare-artifacts-repo-host-design.md`

## Global Constraints

- Toolchain: `swift test` needs `DEVELOPER_DIR` pointing at Xcode 27 (see memory note; default CLT swift is too old).
- Conventional commits, subject ≤72 chars, issue number in subject: `feat(#1266): …`.
- Doc comments on public API follow `docs/comment-style-guide.md`; DocC strict mode fails on partial `- Parameters:` blocks — write complete ones or none.
- `RemoteRepo`'s "is this site published?" invariant stays conservative: unknown hosts must still parse to `nil`.
- Artifacts is private beta: **no code in these slices may change runtime behavior for GitHub-hosted sites**, and the OAuth token template (`permissionGroups`) must NOT gain an artifacts entry yet (a guessed permission-group key would break the dashboard prefill for everyone). The inert constant in Task 4 is the hook slice 3 flips.
- Assumed-API values (verify against beta before slice 3): host `artifacts.cloudflare.com`; endpoint `accounts/{accountID}/artifacts/repos`; result payload `{"name": …}`. Each is defined exactly once (Tasks 1 and 2) and doc-commented as unverified.
- Do not run two `swift test` full-suite invocations concurrently with other agents on this machine (FoundationModels suite contention).

## Execution setup (before Task 1)

This plan's commits must land on a **code branch separate from the docs PR (#1473)**. Before
Task 1, create a fresh worktree off `main` and claim the issue:

```bash
git -C "$(git rev-parse --git-common-dir)/.." worktree add .claude/worktrees/1266-slices-1-2 -b feat/1266-slices-1-2 main
cd "$(git rev-parse --git-common-dir)/../.claude/worktrees/1266-slices-1-2"
gh issue edit 1266 --add-label "🛠️ In Progress"
```

All Task 1–5 commands run from that worktree. (No `xcodegen generate` needed — these slices never
touch the app target; `swift test` works from the bare checkout with `DEVELOPER_DIR` set.)

---

### Task 1: `RepoHost` enum + host-agnostic `RemoteRepo.parse`

**Files:**
- Modify: `Sources/AnglesiteCore/RepoBootstrapTypes.swift` (the `RemoteRepo` struct, lines ~1–60)
- Test: `Tests/AnglesiteCoreTests/RemoteRepoTests.swift`

**Interfaces:**
- Consumes: existing `RemoteRepo` (url/owner/name, `parse(remoteURL:)`).
- Produces: `public enum RepoHost { case github, cloudflareArtifacts }` with `static let artifactsHostName: String`, `static func match(hostName:) -> RepoHost?`, `func browseURL(owner:name:) -> URL?`; `RemoteRepo.host: RepoHost` (init default `.github`). Task 2 constructs `RemoteRepo(url:owner:name:host: .cloudflareArtifacts)` via `RepoHost.cloudflareArtifacts.browseURL(owner:name:)`.

- [ ] **Step 1: Write the failing tests**

Append to the `RemoteRepoTests` suite in `Tests/AnglesiteCoreTests/RemoteRepoTests.swift`:

```swift
    @Test func parsesArtifactsHTTPSRemote() {
        let raw = "https://\(RepoHost.artifactsHostName)/acct123/my-site.git"
        let repo = RemoteRepo.parse(remoteURL: raw)
        #expect(repo?.host == .cloudflareArtifacts)
        #expect(repo?.owner == "acct123")
        #expect(repo?.name == "my-site")
        #expect(repo?.url == URL(string: "https://\(RepoHost.artifactsHostName)/acct123/my-site"))
    }

    @Test func parsesArtifactsSSHRemote() {
        let repo = RemoteRepo.parse(remoteURL: "git@\(RepoHost.artifactsHostName):acct123/my-site.git")
        #expect(repo?.host == .cloudflareArtifacts)
        #expect(repo?.url == URL(string: "https://\(RepoHost.artifactsHostName)/acct123/my-site"))
    }

    @Test func githubRemoteParsesWithGitHubHost() {
        #expect(RemoteRepo.parse(remoteURL: "https://github.com/acme/site.git")?.host == .github)
    }

    @Test func stillRejectsUnknownHosts() {
        #expect(RemoteRepo.parse(remoteURL: "https://gitlab.com/foo/bar.git") == nil)
        #expect(RemoteRepo.parse(remoteURL: "git@bitbucket.org:foo/bar.git") == nil)
    }
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `swift test --package-path . --filter RemoteRepoTests`
Expected: compile FAILURE — `RepoHost` and `host` don't exist yet. (Note: `--filter` still compiles the whole package.)

- [ ] **Step 3: Implement `RepoHost` and generalize `RemoteRepo`**

In `Sources/AnglesiteCore/RepoBootstrapTypes.swift`, add above `RemoteRepo`:

```swift
/// A git-hosting provider the app recognizes in a site's `origin` remote. Owns host matching and
/// browse-URL derivation so `RemoteRepo` consumers never re-parse URLs to learn the provider.
public enum RepoHost: String, CaseIterable, Codable, Sendable {
    /// GitHub (`github.com`) — the original provider; `gh`/REST bootstrap paths.
    case github
    /// Cloudflare Artifacts — private beta. Host and URL shapes are assumed pending beta access;
    /// ``artifactsHostName`` is the single value to correct once verified (#1266).
    case cloudflareArtifacts

    /// The Artifacts git/browse host. Unverified private-beta assumption — the one place to fix.
    public static let artifactsHostName = "artifacts.cloudflare.com"

    /// The provider for a remote's host name, or nil for hosts the app doesn't recognize —
    /// callers treat nil as "not published", never as an error.
    public static func match(hostName: String) -> RepoHost? {
        switch hostName.lowercased() {
        case "github.com", "www.github.com": .github
        case artifactsHostName: .cloudflareArtifacts
        default: nil
        }
    }

    /// Browser URL for a repo on this host (no `.git` suffix).
    public func browseURL(owner: String, name: String) -> URL? {
        switch self {
        case .github: URL(string: "https://github.com/\(owner)/\(name)")
        case .cloudflareArtifacts: URL(string: "https://\(Self.artifactsHostName)/\(owner)/\(name)")
        }
    }
}
```

Then in `RemoteRepo`:

1. Add the stored property after `name`:
```swift
    /// Which provider hosts this remote — derived from the host in `parse(remoteURL:)`.
    public let host: RepoHost
```
2. Extend the memberwise init (default keeps ~all existing call sites — `HTTPGitHubClient`, tests — source-compatible):
```swift
    public init(url: URL, owner: String, name: String, host: RepoHost = .github) {
        self.url = url
        self.owner = owner
        self.name = name
        self.host = host
    }
```
3. In `parse(remoteURL:)`, replace the github-only guard
   (`guard host.lowercased() == "github.com" || … else { return nil }`) and the final
   `URL(string: "https://github.com/…")` construction with:
```swift
        guard let repoHost = RepoHost.match(hostName: host) else { return nil }

        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty, let browse = repoHost.browseURL(owner: owner, name: name) else {
            return nil
        }
        return RemoteRepo(url: browse, owner: owner, name: name, host: repoHost)
```
4. Update the type-level doc comment ("A site's GitHub remote…") to say "A site's git remote
   (GitHub or Cloudflare Artifacts)…" and drop the "host is not github.com" claim from
   `parse`'s doc comment in favor of "hosts `RepoHost` doesn't recognize".

- [ ] **Step 4: Run the AnglesiteCore suite**

Run: `swift test --package-path . --filter "RemoteRepoTests|RepoBootstrapTests|GHRepoProviderTests|HTTPRepoProviderTests|GitRemoteResolverTests"`
Expected: PASS (all pre-existing tests unchanged and green — the refactor is behavior-preserving for GitHub remotes).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoBootstrapTypes.swift Tests/AnglesiteCoreTests/RemoteRepoTests.swift
git commit -m "feat(#1266): host-agnostic RemoteRepo via RepoHost enum"
```

---

### Task 2: `ArtifactsAPIError` + `HTTPArtifactsClient.createRepo`

**Files:**
- Create: `Sources/AnglesiteCore/HTTPArtifactsClient.swift`
- Test: `Tests/AnglesiteCoreTests/HTTPArtifactsClientTests.swift` (create)

**Interfaces:**
- Consumes: `RepoHost` / `RemoteRepo(url:owner:name:host:)` from Task 1; `CloudflareTransport` typealias and `HTTPCloudflareClient.defaultTransport` (existing).
- Produces: `public enum ArtifactsAPIError` (`network`, `unauthorized(status: Int)`, `http(status: Int)`, `api(message: String)`, `malformedResponse`); `public struct HTTPArtifactsClient` with `init(baseURL:transport:)` and `createRepo(name:isPrivate:accountID:token:) async throws -> RemoteRepo`. Task 3 adds `probeAvailability` to this same type.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/HTTPArtifactsClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct HTTPArtifactsClientTests {
    /// Scripted transport: returns `(data, status)` and records the request it saw.
    private final class Recorder: @unchecked Sendable {
        var request: URLRequest?
    }

    private func client(status: Int, json: String, recorder: Recorder? = nil) -> HTTPArtifactsClient {
        HTTPArtifactsClient(transport: { request in
            recorder?.request = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        })
    }

    @Test func createRepoSendsAuthorizedPOSTToAccountEndpoint() async throws {
        let recorder = Recorder()
        let ok = #"{"success":true,"errors":[],"result":{"name":"my-site"}}"#
        _ = try await client(status: 200, json: ok, recorder: recorder)
            .createRepo(name: "my-site", isPrivate: true, accountID: "acct123", token: "tok")
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("accounts/acct123/artifacts/repos") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["name"] as? String == "my-site")
        #expect(body?["private"] as? Bool == true)
    }

    @Test func createRepoBuildsArtifactsRemoteRepo() async throws {
        let ok = #"{"success":true,"errors":[],"result":{"name":"my-site"}}"#
        let repo = try await client(status: 200, json: ok)
            .createRepo(name: "my-site", isPrivate: true, accountID: "acct123", token: "tok")
        #expect(repo.host == .cloudflareArtifacts)
        #expect(repo.owner == "acct123")
        #expect(repo.name == "my-site")
        #expect(repo.url == RepoHost.cloudflareArtifacts.browseURL(owner: "acct123", name: "my-site"))
    }

    @Test func createRepoMapsUnauthorized() async {
        await #expect(throws: ArtifactsAPIError.unauthorized(status: 403)) {
            _ = try await client(status: 403, json: "{}")
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoSurfacesAPIErrorMessage() async {
        let err = #"{"success":false,"errors":[{"code":1000,"message":"repository already exists"}],"result":null}"#
        await #expect(throws: ArtifactsAPIError.api(message: "repository already exists")) {
            _ = try await client(status: 200, json: err)
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoMapsHTTPFailure() async {
        await #expect(throws: ArtifactsAPIError.http(status: 500)) {
            _ = try await client(status: 500, json: "oops")
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoMapsTransportFailureToNetwork() async {
        let failing = HTTPArtifactsClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: ArtifactsAPIError.network) {
            _ = try await failing.createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter HTTPArtifactsClientTests`
Expected: compile FAILURE — `HTTPArtifactsClient` doesn't exist.

- [ ] **Step 3: Implement the client**

Create `Sources/AnglesiteCore/HTTPArtifactsClient.swift`:

```swift
import Foundation
// URLSession types live in FoundationNetworking on non-Darwin platforms.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failure taxonomy for the Cloudflare Artifacts REST API, mirroring `GitHubRepoAPIError` so
/// `ArtifactsRepoProvider` (slice 3, #1266) can map cases to owner-facing messages the same way.
/// Duplicate-name failures arrive as `.api(message:)` with Cloudflare's own message — the API's
/// error codes are unverified in private beta, so none are special-cased yet.
public enum ArtifactsAPIError: Error, Equatable, Sendable {
    /// The request never got an HTTP response (offline, DNS, TLS).
    case network
    /// 401/403 — the token lacks Artifacts access (or beta enrollment).
    case unauthorized(status: Int)
    /// Any other non-2xx status.
    case http(status: Int)
    /// A 2xx envelope with `success: false`; carries Cloudflare's first error message verbatim.
    case api(message: String)
    /// A 2xx envelope that didn't decode.
    case malformedResponse
}

/// Cloudflare Artifacts REST client. Endpoint path and response shape are private-beta
/// assumptions (#1266) — kept in this one file, alongside `RepoHost.artifactsHostName`, so beta
/// verification is a single-file correction. Only creates the remote repository; wiring `origin`
/// and pushing is `ArtifactsRepoProvider`'s job (slice 3), matching the `HTTPGitHubClient` split.
public struct HTTPArtifactsClient: Sendable {
    private let baseURL: URL
    private let transport: CloudflareTransport

    /// Creates a client. Both parameters exist for tests — production callers take the defaults.
    public init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Creates a repository under the account and returns it as a `RemoteRepo` with
    /// `host == .cloudflareArtifacts` and `owner == accountID`.
    public func createRepo(name: String, isPrivate: Bool, accountID: String, token: String) async throws -> RemoteRepo {
        struct Body: Encodable {
            let name: String
            let isPrivate: Bool
            enum CodingKeys: String, CodingKey { case name, isPrivate = "private" }
        }
        let data = try await send(
            path: "accounts/\(accountID)/artifacts/repos",
            method: "POST",
            body: try JSONEncoder().encode(Body(name: name, isPrivate: isPrivate)),
            token: token)

        struct Result: Decodable { let name: String }
        let result: Result = try Self.decodeEnvelope(data)
        guard let url = RepoHost.cloudflareArtifacts.browseURL(owner: accountID, name: result.name) else {
            throw ArtifactsAPIError.malformedResponse
        }
        return RemoteRepo(url: url, owner: accountID, name: result.name, host: .cloudflareArtifacts)
    }

    /// Sends one authenticated request; maps transport/status failures to `ArtifactsAPIError`.
    private func send(path: String, method: String, body: Data?, token: String) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw ArtifactsAPIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw ArtifactsAPIError.network
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ArtifactsAPIError.unauthorized(status: http.statusCode)
        default: throw ArtifactsAPIError.http(status: http.statusCode)
        }
    }

    /// Unwraps Cloudflare's `{success, errors, result}` envelope; `success: false` becomes
    /// `.api(message:)` with the first error message.
    private static func decodeEnvelope<T: Decodable>(_ data: Data) throws -> T {
        struct Envelope<R: Decodable>: Decodable {
            let success: Bool
            let errors: [APIMessage]?
            let result: R?
            struct APIMessage: Decodable { let message: String }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw ArtifactsAPIError.malformedResponse
        }
        guard envelope.success, let result = envelope.result else {
            throw ArtifactsAPIError.api(message: envelope.errors?.first?.message ?? "Cloudflare returned an unexpected response.")
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter HTTPArtifactsClientTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPArtifactsClient.swift Tests/AnglesiteCoreTests/HTTPArtifactsClientTests.swift
git commit -m "feat(#1266): Cloudflare Artifacts API client (createRepo)"
```

---

### Task 3: Strict availability probe (the beta gate)

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPArtifactsClient.swift` (add one method)
- Test: `Tests/AnglesiteCoreTests/HTTPArtifactsClientTests.swift` (extend)

**Interfaces:**
- Consumes: `HTTPArtifactsClient.send`/`decodeEnvelope` from Task 2.
- Produces: `func probeAvailability(accountID: String, token: String) async -> Bool`. Slice 3's bootstrap selection calls this (accountID from the existing `HTTPCloudflareClient.accountID(apiToken:)`).

**Design note (spec §6 refinement):** `CloudflareCapabilityProber.allowed` deliberately counts any non-401/403 — including 404 — as proof, because "product not enabled" 404s still prove the permission group. That semantic is wrong for a private-beta gate: an account *without* Artifacts access likely gets 404, which must read as **unavailable**. So the Artifacts gate lives on the client with strict 2xx + `success: true` semantics instead of a `TokenCapability` case. The prober is untouched.

- [ ] **Step 1: Write the failing tests**

Append to `HTTPArtifactsClientTests`:

```swift
    @Test func probeAvailabilityTrueOnSuccessEnvelope() async {
        let ok = #"{"success":true,"errors":[],"result":[]}"#
        let available = await client(status: 200, json: ok)
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(available)
    }

    @Test func probeAvailabilityFalseWithoutBetaAccess() async {
        // 404 = endpoint unknown to this account (no beta); must NOT read as available,
        // unlike CloudflareCapabilityProber's permissive not-401/403 semantics.
        let unavailable404 = await client(status: 404, json: "{}")
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(unavailable404 == false)
        let unavailable403 = await client(status: 403, json: "{}")
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(unavailable403 == false)
    }

    @Test func probeAvailabilityFalseOnTransportFailure() async {
        let failing = HTTPArtifactsClient(transport: { _ in throw URLError(.timedOut) })
        let available = await failing.probeAvailability(accountID: "a", token: "t")
        #expect(available == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter HTTPArtifactsClientTests`
Expected: compile FAILURE — `probeAvailability` doesn't exist.

- [ ] **Step 3: Implement**

Add to `HTTPArtifactsClient`:

```swift
    /// True when the account can list Artifacts repos — the #1266 private-beta gate. Strict on
    /// purpose: only a 2xx `success: true` envelope counts, so a 404 from an account without
    /// beta access reads as unavailable (`CloudflareCapabilityProber`'s permissive not-401/403
    /// rule would get this wrong). Advisory like all probes — callers may re-probe.
    public func probeAvailability(accountID: String, token: String) async -> Bool {
        struct Repo: Decodable {}
        guard let data = try? await send(
            path: "accounts/\(accountID)/artifacts/repos?per_page=1",
            method: "GET", body: nil, token: token)
        else { return false }
        return (try? Self.decodeEnvelope(data) as [Repo]) != nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter HTTPArtifactsClientTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPArtifactsClient.swift Tests/AnglesiteCoreTests/HTTPArtifactsClientTests.swift
git commit -m "feat(#1266): strict Artifacts availability probe (beta gate)"
```

---

### Task 4: Inert OAuth permission-group hook + full-suite verification

**Files:**
- Modify: `Sources/AnglesiteCore/AnglesiteTokenTemplate.swift`
- Test: `Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift` (extend if it exists; create the suite in that file otherwise)

**Interfaces:**
- Consumes: `AnglesiteTokenTemplate.permissionGroups` / `oauthScope` (existing).
- Produces: `public static let artifactsPermissionGroup: (key: String, type: String)` — slice 3 appends it to `permissionGroups` once the beta key is verified, which automatically extends `oauthScope` and the dashboard deep link.

- [ ] **Step 1: Write the failing test**

In `Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift` (extend the existing suite, or create `@Suite struct AnglesiteTokenTemplateTests` with the standard `import Testing` / `@testable import AnglesiteCore` header if the file doesn't exist):

```swift
    /// #1266 slices 1–2 must not touch the live token template: an unverified permission-group
    /// key in the dashboard prefill would break token creation for every user. Slice 3 flips
    /// this by appending `artifactsPermissionGroup` to `permissionGroups` once verified.
    @Test func artifactsPermissionGroupIsDefinedButNotYetRequested() {
        #expect(AnglesiteTokenTemplate.artifactsPermissionGroup.type == "edit")
        #expect(!AnglesiteTokenTemplate.permissionGroups
            .contains { $0.key == AnglesiteTokenTemplate.artifactsPermissionGroup.key })
        #expect(!AnglesiteTokenTemplate.oauthScope
            .contains(AnglesiteTokenTemplate.artifactsPermissionGroup.key))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AnglesiteTokenTemplateTests`
Expected: compile FAILURE — `artifactsPermissionGroup` doesn't exist.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/AnglesiteTokenTemplate.swift`, below `permissionGroups`:

```swift
    /// The Artifacts permission group (#1266) — deliberately **not** in ``permissionGroups`` yet.
    /// The key is an unverified private-beta assumption, and an unknown key in the dashboard
    /// prefill would break token creation for everyone. Slice 3 appends this once verified,
    /// which extends ``oauthScope`` and ``createTokenURL`` automatically.
    public static let artifactsPermissionGroup: (key: String, type: String) = ("artifacts", "edit")
```

- [ ] **Step 4: Run the full suite**

Run: `swift test --package-path .`
Expected: PASS across all targets (this is the pre-PR gate from CONTRIBUTING; no template or app-target sources changed, so no xcodebuild/localization steps are needed).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AnglesiteTokenTemplate.swift Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift
git commit -m "feat(#1266): inert Artifacts OAuth permission-group hook"
```

---

### Task 5: PR

- [ ] **Step 1: Verify the branch**

Confirm you are on `feat/1266-slices-1-2` (created in Execution setup) with exactly the four
Task 1–4 commits: `git log --oneline main..HEAD` should list four `feat(#1266): …` subjects and
`git status --short` should be clean.

- [ ] **Step 2: Push and open the PR with the template's exact headings**

Body must use `.github/PULL_REQUEST_TEMPLATE.md`'s sections verbatim (**Summary**, **Paired PR check**, **Test plan**). This PR does **not** close #1266 (it's the epic) — delete the `Closes #` line and say "Part of #1266" in the Summary. Paired PR check: self-contained (no MCP schema change). Test plan: check the `swift test` box (run in Task 4); xcodebuild unchecked with the note "no app-target sources touched".

```bash
git push -u origin feat/1266-slices-1-2
gh pr create --base main --title "feat(#1266): Artifacts RepoHost + API client (slices 1-2)"
```

---

## Verification checklist (executor)

- [ ] `swift test --package-path .` green (Task 4 step 4).
- [ ] No diff under `Resources/Template/`, `Sources/AnglesiteApp/`, or `project.yml` (slices 1–2 are AnglesiteCore-only; anything else is scope creep).
- [ ] Every assumed-API value (`artifactsHostName`, endpoint path, result shape, permission-group key) carries a doc comment naming it unverified + #1266.
- [ ] Commit subjects ≤72 chars, conventional format.
