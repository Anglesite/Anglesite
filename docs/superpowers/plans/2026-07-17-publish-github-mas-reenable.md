# Publish to GitHub: Re-enable for MAS (#654) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Publish to GitHub" reachable and working in the one shipping (MAS) build of Anglesite, replacing the dead/broken `gh auth login` flow with a token-prompt flow that actually feeds the Keychain slot `HTTPRepoProvider` reads.

**Architecture:** Delete the unreachable `gh`-CLI auth UI (`GitHubAuthSheetView`/`GitHubAuthFlow`/`GitHubAuthRow`), remove the `#if !ANGLESITE_MAS` gates hiding the working toolbar/menu/sheet UI, and add a `.needsAuth` flow that mirrors `DeployModel`'s existing "blocked on missing Cloudflare token" pattern: a new `GitHubTokenOnboarding` core type (testable under `swift test`) plus a `GitHubTokenPromptView` (SwiftUI, modeled on `CloudflareTokenPromptView`) wired into `PublishModel`.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`@Test`/`#expect`), SwiftPM (`swift test --package-path .`), Xcode 27 (`xcodebuild`).

## Global Constraints

- `ANGLESITE_MAS` is defined for every current build configuration (`project.yml`'s Xcode scheme *and* `Package.swift:238`'s `AnglesiteAppCore` SPM target) — confirmed via `grep -n "ANGLESITE_MAS" project.yml Package.swift`. All `#if !ANGLESITE_MAS` code in this feature area is dead in every config today; no build variant depends on it.
- Full design/rationale lives in `docs/superpowers/specs/2026-07-17-publish-github-mas-reenable-design.md` — read it if a task's "why" isn't obvious from context alone.
- Conventional commits, referencing `#654` in the subject (per `CONTRIBUTING.md`).
- Run `swift test --package-path .` after every task that touches `Sources/AnglesiteCore` or `Sources/AnglesiteApp`. Run `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` at minimum after Task 5 (the un-gating task) and before the final manual smoke.
- The worktree's `Anglesite.xcodeproj` is gitignored and generated from `project.yml`. Adding/removing `.swift` files under a globbed `sources:` path (e.g. `Sources/AnglesiteApp`, `Sources/AnglesiteCore`) requires re-running `xcodegen generate` before Xcode will see the change — `project.yml` itself does not need editing since it globs directories.
- No new third-party dependencies. Everything needed (`GitHubAPITokenVerifier`, `KeychainStore`, `AppSettings.gitHubAccount`, `HTTPRepoProvider`) already exists from #659/#663/#779.
- Don't touch `RepoBootstrap`'s SwiftGit2/HTTP plumbing, `HTTPRepoProvider`, `HTTPGitHubClient`, or the non-Darwin `GHRepoProvider` path — out of scope (see spec's "Non-goals").

---

### Task 1: Delete the dead gh-CLI GitHub auth path

**Files:**
- Delete: `Sources/AnglesiteApp/GitHubAuthSheetView.swift`
- Delete: `Sources/AnglesiteCore/GitHubAuthFlow.swift`
- Delete: `Tests/AnglesiteCoreTests/GitHubAuthFlowTests.swift`
- Modify: `Sources/AnglesiteApp/SettingsView.swift:317-354` (collapse Credentials section), `:438-443` (stale doc comment), `:649-779` (remove `GitHubAuthRow` + `ResolveBinary`)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — this task only removes unreachable code. `KeychainTokenRow` (already defined at `SettingsView.swift:444-647`, untouched) becomes the Credentials section's only GitHub row.

- [ ] **Step 1: Confirm nothing outside the files being touched references the doomed symbols**

Run:
```bash
grep -rln "GitHubAuthFlow\|GitHubAuthSheetView\|GitHubAuthRow\|ResolveBinary" --include="*.swift" . | grep -v .build
```
Expected output — exactly these four files (all being deleted or edited in this task):
```
Tests/AnglesiteCoreTests/GitHubAuthFlowTests.swift
Sources/AnglesiteApp/SettingsView.swift
Sources/AnglesiteApp/GitHubAuthSheetView.swift
Sources/AnglesiteCore/GitHubAuthFlow.swift
```
If any other file appears, stop and investigate before deleting — do not proceed with a stale reference left dangling.

- [ ] **Step 2: Delete the three dead files**

```bash
git rm Sources/AnglesiteApp/GitHubAuthSheetView.swift
git rm Sources/AnglesiteCore/GitHubAuthFlow.swift
git rm Tests/AnglesiteCoreTests/GitHubAuthFlowTests.swift
```

- [ ] **Step 3: Collapse `SettingsView.swift`'s Credentials section to the single GitHub row**

Replace lines 317-354 (the `Section("Credentials")` block):

```swift
            Section("Credentials") {
                CloudflareTokenRow()
                Text("Stored in the macOS Keychain under `io.dwk.anglesite`. The token is passed to `wrangler deploy` as `CLOUDFLARE_API_TOKEN` and never written to logs. An exported `CLOUDFLARE_API_TOKEN` in the shell that launched Anglesite takes precedence over this entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if !ANGLESITE_MAS
                GitHubAuthRow()
                Text("Anglesite shells out to `gh` for GitHub operations and does not store the token itself — `gh` keeps it in its own keychain entry. Clicking Connect runs `gh auth login`; sign-out is `gh auth logout` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                KeychainTokenRow(
                    title: "GitHub personal access token",
                    read: { try KeychainStore().readGitHubToken() },
                    write: { try KeychainStore().writeGitHubToken($0) },
                    clear: {
                        try KeychainStore().clearGitHubToken()
                        AppSettings.shared.gitHubAccount = nil
                    },
                    verify: { token in
                        switch await GitHubAPITokenVerifier().verify(token: token) {
                        case .success(let account):
                            AppSettings.shared.gitHubAccount = account
                            return .success(.init(label: account.login, detail: account.name, avatarURL: account.avatarURL))
                        case .failure(let error):
                            return .failure(error.userMessage)
                        }
                    },
                    cachedIdentity: {
                        AppSettings.shared.gitHubAccount.map { .init(label: $0.login, detail: $0.name, avatarURL: $0.avatarURL) }
                    }
                )
                Text("Used to push backups and publish sites to GitHub over HTTPS (the sandboxed app can't run `git` or `gh`, so it pushes in-process with this token). Create a fine-grained token with Contents read/write access at github.com/settings/tokens. Stored in the macOS Keychain under `io.dwk.anglesite` and never written to logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
```

with:

```swift
            Section("Credentials") {
                CloudflareTokenRow()
                Text("Stored in the macOS Keychain under `io.dwk.anglesite`. The token is passed to `wrangler deploy` as `CLOUDFLARE_API_TOKEN` and never written to logs. An exported `CLOUDFLARE_API_TOKEN` in the shell that launched Anglesite takes precedence over this entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                KeychainTokenRow(
                    title: "GitHub personal access token",
                    read: { try KeychainStore().readGitHubToken() },
                    write: { try KeychainStore().writeGitHubToken($0) },
                    clear: {
                        try KeychainStore().clearGitHubToken()
                        AppSettings.shared.gitHubAccount = nil
                    },
                    verify: { token in
                        switch await GitHubAPITokenVerifier().verify(token: token) {
                        case .success(let account):
                            AppSettings.shared.gitHubAccount = account
                            return .success(.init(label: account.login, detail: account.name, avatarURL: account.avatarURL))
                        case .failure(let error):
                            return .failure(error.userMessage)
                        }
                    },
                    cachedIdentity: {
                        AppSettings.shared.gitHubAccount.map { .init(label: $0.login, detail: $0.name, avatarURL: $0.avatarURL) }
                    }
                )
                Text("Used to push backups and publish sites to GitHub over HTTPS (the sandboxed app can't run `git` or `gh`, so it pushes in-process with this token). Create a fine-grained token with Contents read/write access at github.com/settings/tokens. Stored in the macOS Keychain under `io.dwk.anglesite` and never written to logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Fix the stale doc comment on `KeychainTokenRow`**

Find (around what was line 441 before Step 3's edit shifted things — search for the text, don't rely on the line number):

```swift
/// success, surfaces the connected account — "Signed in as octocat" with an avatar for GitHub,
/// a checkmark + account name for Cloudflare — instead of a bare "Saved." This mirrors Xcode's
/// Accounts pane, which shows who you're signed in as rather than just "credential stored", and
/// matches `GitHubAuthRow` below (the non-MAS `gh`-backed row already does this). `verify`
/// defaults to `nil` — a future token slot with nothing to verify against just omits it and
/// keeps the plain "Saved."/"Token stored" behavior.
```

Replace with:

```swift
/// success, surfaces the connected account — "Signed in as octocat" with an avatar for GitHub,
/// a checkmark + account name for Cloudflare — instead of a bare "Saved." This mirrors Xcode's
/// Accounts pane, which shows who you're signed in as rather than just "credential stored".
/// `verify` defaults to `nil` — a future token slot with nothing to verify against just omits it
/// and keeps the plain "Saved."/"Token stored" behavior.
```

- [ ] **Step 5: Delete `GitHubAuthRow` and `ResolveBinary`**

Find the block starting at the comment just above `#if !ANGLESITE_MAS` (search for `"The gh-backed GitHub panel is compiled out"`) through the matching `#endif`:

```swift
// The gh-backed GitHub panel is compiled out of the App Store build. A sandboxed app can't rely
// on a user-installed `gh` (nor spawn `git` at all, #640) — it stores its own GitHub token and
// pushes in-process instead; see the KeychainTokenRow in the #else branch above (#653).
#if !ANGLESITE_MAS
/// "Connect GitHub" row. The app never sees the GitHub token — `gh` stores it in its own
/// credential store. This row just launches the `gh auth login` device-code flow and
/// surfaces the result. Status reflects what `gh auth status` reports at appear-time.
private struct GitHubAuthRow: View {
    @State private var status: Status = .unknown
    @State private var sheetPresented = false
    @State private var resultMessage: ResultMessage?

    private enum Status: Equatable {
        case unknown
        case signedIn(account: String)
        case signedOut
        case unavailable(String)
    }

    private struct ResultMessage: Equatable {
        let text: String
        let isError: Bool
    }

    var body: some View {
        LabeledContent("GitHub") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    statusLabel
                    Spacer()
                    Button("Connect…") {
                        resultMessage = nil
                        sheetPresented = true
                    }
                    .disabled(isUnavailable)
                    .accessibilityHint(isUnavailable ? "GitHub tools are unavailable on this Mac" : "")
                }
                if let resultMessage {
                    Text(resultMessage.text)
                        .font(.caption)
                        .foregroundStyle(resultMessage.isError ? .red : .secondary)
                }
            }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $sheetPresented) {
            GitHubAuthSheetView { result in
                sheetPresented = false
                switch result {
                case .authenticated:
                    resultMessage = ResultMessage(text: "Connected.", isError: false)
                    Task { await refreshStatus() }
                case .failed(let reason):
                    resultMessage = ResultMessage(text: reason, isError: true)
                case .cancelled:
                    resultMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .signedIn(let account):
            Label("Signed in as \(account)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .signedOut:
            Text("Not signed in").foregroundStyle(.secondary)
        case .unknown:
            Text("Checking…").foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).foregroundStyle(.orange).font(.caption)
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { return true }
        return false
    }

    private func refreshStatus() async {
        // Probe `gh auth status` — robust to gh not being installed.
        guard let gh = ResolveBinary.locate("gh") else {
            status = .unavailable("`gh` not installed (brew install gh).")
            return
        }
        let result: ProcessSupervisor.RunResult
        do {
            result = try await ProcessSupervisor.shared.run(
                executable: gh,
                arguments: ["auth", "status", "--hostname", "github.com"]
            )
        } catch {
            status = .unavailable("couldn't run `gh`: \(error.localizedDescription)")
            return
        }
        // gh writes its status to stderr; combine both streams as the old single-pipe code did.
        let output = result.stdout + result.stderr
        if result.exitCode == 0 {
            // Look for "account davidwkeith" or "Logged in to github.com account <name>"
            if let range = output.range(of: #"account\s+(\S+)"#, options: .regularExpression) {
                let token = output[range].split(separator: " ").last.map(String.init) ?? ""
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                status = .signedIn(account: cleaned)
            } else {
                status = .signedOut
            }
        } else {
            status = .signedOut
        }
    }
}

/// Tiny PATH-walker for finding a binary by name. Avoids depending on `which` (which itself
/// requires a shell), and respects the environment Anglesite was launched with.
private enum ResolveBinary {
    static func locate(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
#endif
```

Delete the entire block (comment, `#if`, both types, `#endif`), leaving a single blank line before `private struct FolderPickerRow: View {`.

- [ ] **Step 6: Build and test**

```bash
swift build --target AnglesiteCore --target AnglesiteAppCore
swift test --package-path . --filter AnglesiteCoreTests
swift test --package-path . --filter AnglesiteAppTests
```
Expected: clean build, all tests pass (no test referenced the deleted symbols per Step 1's grep).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "fix(app): delete dead gh-CLI GitHub auth path (#654)

GitHubAuthSheetView/GitHubAuthFlow/GitHubAuthRow only compiled under
#if !ANGLESITE_MAS, which is never true in any current build config
(the Xcode scheme and Package.swift's AnglesiteAppCore target both
always define ANGLESITE_MAS). Even where it used to compile, gh auth
login wrote the token to gh's own credential store, not the Keychain
slot HTTPRepoProvider reads — an unreachable, broken code path."
```

---

### Task 2: `GitHubTokenOnboarding` core type + tests

**Files:**
- Create: `Sources/AnglesiteCore/GitHubTokenOnboarding.swift`
- Create: `Tests/AnglesiteCoreTests/GitHubTokenOnboardingTests.swift`

**Interfaces:**
- Consumes: `GitHubTokenVerifying` protocol, `GitHubAccount`, `GitHubTokenVerifyError` (all existing, `Sources/AnglesiteCore/GitHubAPITokenVerifier.swift`).
- Produces: `GitHubTokenOnboarding` (public `@MainActor` struct) with `init(verifier: GitHubTokenVerifying)` and `func run(token: String, persist: (String) throws -> Void, onConnected: (GitHubAccount) -> Void, delay: () async -> Void, isCancelled: () -> Bool) async -> Outcome`, where `Outcome` is `.proceed(GitHubAccount) | .stay(message: String) | .abort`. Task 3 (`PublishModel`) consumes this exact signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/GitHubTokenOnboardingTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Tests the verify → persist → (maybe) proceed orchestration in isolation from any UI, mirroring
/// `TokenOnboardingTests` (Cloudflare). Cancellation is an injected predicate rather than a real
/// race, so the "cancelled publish must not fire" rule is asserted deterministically — and, unlike
/// a hosted app test, this runs under `swift test`.
@MainActor
struct GitHubTokenOnboardingTests {
    private struct StubVerifier: GitHubTokenVerifying {
        let result: Result<GitHubAccount, GitHubTokenVerifyError>
        func verify(token: String) async -> Result<GitHubAccount, GitHubTokenVerifyError> {
            result
        }
    }

    private let account = GitHubAccount(login: "octocat", name: "The Octocat", avatarURL: nil)

    @Test("A verified token that isn't cancelled yields .proceed and persists once")
    func proceedsWhenNotCancelled() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        var connected: GitHubAccount?
        let outcome = await onboarding.run(
            token: "  tok  ",
            persist: { _ in persistCount += 1 },
            onConnected: { connected = $0 },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .proceed(account))
        #expect(persistCount == 1)
        #expect(connected == account)
    }

    @Test("Cancellation after a successful verify yields .abort (no proceed)")
    func abortsWhenCancelled() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "tok",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { true }
        )
        #expect(outcome == .abort)
        // The token verified, so it's still persisted; only the publish retry is skipped.
        #expect(persistCount == 1)
    }

    @Test("A failed verification yields .stay and never persists")
    func staysOnFailure() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .failure(.invalidToken)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "bad",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        #expect(outcome == .stay(message: GitHubTokenVerifyError.invalidToken.userMessage))
        #expect(persistCount == 0)
    }

    @Test("An empty token stays without verifying or persisting")
    func staysOnEmpty() async {
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        var persistCount = 0
        let outcome = await onboarding.run(
            token: "   ",
            persist: { _ in persistCount += 1 },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
        #expect(persistCount == 0)
    }

    @Test("A persist failure surfaces as .stay, not .proceed")
    func staysWhenPersistThrows() async {
        struct Boom: Error {}
        let onboarding = GitHubTokenOnboarding(verifier: StubVerifier(result: .success(account)))
        let outcome = await onboarding.run(
            token: "tok",
            persist: { _ in throw Boom() },
            onConnected: { _ in },
            delay: {},
            isCancelled: { false }
        )
        if case .stay = outcome {} else { Issue.record("expected .stay, got \(outcome)") }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

```bash
swift test --package-path . --filter GitHubTokenOnboardingTests
```
Expected: build FAILS — `cannot find type 'GitHubTokenOnboarding' in scope` (it doesn't exist yet).

- [ ] **Step 3: Implement `GitHubTokenOnboarding`**

Create `Sources/AnglesiteCore/GitHubTokenOnboarding.swift`:

```swift
import Foundation

/// Drives the "connect GitHub" token flow — verify the pasted token, persist it only if it's
/// good, surface the connected account, then decide whether to proceed — independent of any
/// SwiftUI. Mirrors `TokenOnboarding` (Cloudflare)'s verify → persist → flash → re-check-cancel →
/// proceed ordering, but against `GitHubTokenVerifying`/`GitHubAccount` and without a
/// `siteDirectory` parameter — GitHub token verification is a plain `GET /user` call with no
/// site-scoped check, unlike Cloudflare's wrangler-based verification. Kept as a separate type
/// rather than generalizing `TokenOnboarding<Account>`, since that would mean touching
/// `DeployModel` too — out of scope for #654.
///
/// `@MainActor` so it composes naturally with `PublishModel` (also MainActor) without `Sendable`
/// gymnastics on the closures.
@MainActor
public struct GitHubTokenOnboarding {
    public enum Outcome: Equatable {
        /// Token verified and persisted — the caller should retry the parked publish.
        case proceed(GitHubAccount)
        /// Verification (or persistence) failed — the caller keeps the prompt open with `message`.
        case stay(message: String)
        /// The user cancelled during the flow — the caller does nothing.
        case abort
    }

    private let verifier: GitHubTokenVerifying

    public init(verifier: GitHubTokenVerifying) {
        self.verifier = verifier
    }

    /// - persist: stores the token (e.g. Keychain write); only called on a successful verify, and a
    ///   throw turns the run into `.stay`.
    /// - onConnected: surfaces the connected account for the success flash, before `delay`.
    /// - delay: the success-flash pause — injectable so tests don't wait real time.
    /// - isCancelled: re-checked after verify + delay; `true` ⇒ `.abort` (no proceed).
    public func run(
        token: String,
        persist: (String) throws -> Void,
        onConnected: (GitHubAccount) -> Void,
        delay: () async -> Void,
        isCancelled: () -> Bool
    ) async -> Outcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .stay(message: "Paste your token first.") }

        switch await verifier.verify(token: trimmed) {
        case .failure(let error):
            return .stay(message: error.userMessage)
        case .success(let account):
            do {
                try persist(trimmed)
            } catch {
                return .stay(message: "Couldn’t save to Keychain: \(error)")
            }
            // Let the user see which account they connected, then re-check cancellation before
            // retrying the publish behind their back.
            onConnected(account)
            await delay()
            if isCancelled() { return .abort }
            return .proceed(account)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --package-path . --filter GitHubTokenOnboardingTests
```
Expected: PASS, all 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/GitHubTokenOnboarding.swift Tests/AnglesiteCoreTests/GitHubTokenOnboardingTests.swift
git commit -m "feat(core): add GitHubTokenOnboarding for the publish token-prompt flow (#654)"
```

---

### Task 3: Update `PublishModel` for the token-prompt flow

**Files:**
- Modify: `Sources/AnglesiteApp/PublishModel.swift` (full rewrite of the class body — see below)

**Interfaces:**
- Consumes: `GitHubTokenOnboarding` (Task 2), `GitHubTokenVerifying`/`GitHubAPITokenVerifier`/`GitHubAccount` (existing), `KeychainStore` (existing, `Sources/AnglesiteCore/Platform/KeychainStore.swift` — conforms to `SecretStore`, exposes `readGitHubToken`/`writeGitHubToken`/`clearGitHubToken` via the `SecretStore` extension), `AppSettings.shared.gitHubAccount` (existing).
- Produces: `PublishModel.tokenPromptPresented: Bool` (replaces `authSheetPresented`), `PublishModel.tokenVerification: TokenVerification` (new, four cases: `.idle`, `.checking`, `.connected(accountName: String?)`, `.failed(message: String)`), `PublishModel.verifyAndSaveToken(_ token: String) async` (replaces `authCompleted(source:repoName:)`), `PublishModel.cancelTokenPrompt()` (new). Tasks 4 and 5 consume these exact names.

No new tests in this task — `PublishModel` is thin SwiftUI-facing glue with no existing test coverage (same as `DeployModel`); the ordering logic it delegates to is already covered by `GitHubTokenOnboardingTests` (Task 2). This matches the codebase's established pattern of pushing testable logic into `AnglesiteCore` and covering the view-model layer via manual smoke (Task 6).

- [ ] **Step 1: Replace `PublishModel.swift` in full**

Replace the entire contents of `Sources/AnglesiteApp/PublishModel.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `RepoBootstrap`. Drives one publish at a time, mirrors the
/// `DeployModel` shape (a `Phase`, an `isRunning` flag, a sheet-presentation flag). All decision
/// logic lives in `RepoBootstrap`; this only maps events to view state.
@MainActor
@Observable
final class PublishModel {
    enum Phase: Equatable {
        case idle
        case running(milestone: String)
        case needsAuth
        case published(RemoteRepo)
        case failed(reason: String)
    }

    /// Progress of verifying a pasted GitHub token, consumed by `GitHubTokenPromptView`'s status
    /// line and button-enabled logic. Mirrors `DeployModel.TokenVerification` — kept as a separate
    /// type rather than shared, since the two prompts have no other coupling.
    enum TokenVerification: Equatable {
        case idle
        case checking
        case connected(accountName: String?)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    /// Remote read on window open; drives the toolbar label (Publish vs View on GitHub).
    private(set) var existingRemote: RemoteRepo?

    /// Bound to the progress/result sheet in `SiteWindow`.
    var sheetPresented: Bool = false
    /// Bound to `GitHubTokenPromptView` when the provider needs a GitHub token.
    var tokenPromptPresented: Bool = false
    private(set) var tokenVerification: TokenVerification = .idle

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let bootstrap: RepoBootstrap
    private let onboarding: GitHubTokenOnboarding
    private let keychain: KeychainStore
    private var inFlight: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Site parked while the token prompt is open; retried once a token verifies. `nil` outside
    /// that flow.
    private var pendingPublish: (source: URL, repoName: String)?

    init(
        bootstrap: RepoBootstrap = .live(),
        verifier: GitHubTokenVerifying = GitHubAPITokenVerifier(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.bootstrap = bootstrap
        self.onboarding = GitHubTokenOnboarding(verifier: verifier)
        self.keychain = keychain
    }

    /// Cheap read of `origin` to decide the toolbar label. Safe to call on window open; a rapid
    /// re-open cancels the prior read so a late-completing one can't clobber a newer result.
    func refreshRemote(source: URL) {
        refreshTask?.cancel()
        refreshTask = Task { self.existingRemote = await bootstrap.remote(of: source) }
    }

    /// Toolbar action. No-op if a publish is already running.
    func publish(source: URL, repoName: String) {
        start(source: source, repoName: repoName)
    }

    /// Called by the token-prompt sheet's "Connect & publish" button. Verifies the token against
    /// GitHub before persisting it — so a bad token is caught here rather than failing later
    /// inside the publish — then retries the parked publish.
    func verifyAndSaveToken(_ token: String) async {
        guard let pending = pendingPublish else {
            // The prompt is only shown with a parked publish; guard defensively.
            tokenVerification = .failed(message: "No publish is waiting — close this and click Publish again.")
            return
        }

        tokenVerification = .checking
        let outcome = await onboarding.run(
            token: token,
            persist: { try keychain.writeGitHubToken($0) },
            onConnected: { account in
                AppSettings.shared.gitHubAccount = account
                tokenVerification = .connected(accountName: account.login)
            },
            delay: { try? await Task.sleep(for: .milliseconds(700)) },
            isCancelled: { Task.isCancelled || !tokenPromptPresented }
        )

        switch outcome {
        case .proceed:
            pendingPublish = nil
            tokenPromptPresented = false
            tokenVerification = .idle
            start(source: pending.source, repoName: pending.repoName)
        case .stay(let message):
            tokenVerification = .failed(message: message)
        case .abort:
            // The user cancelled mid-flow; `cancelTokenPrompt` already cleared the parked publish.
            tokenVerification = .idle
        }
    }

    func cancelTokenPrompt() {
        pendingPublish = nil
        tokenPromptPresented = false
        tokenVerification = .idle
    }

    func dismiss() { sheetPresented = false }

    /// Single entry point for kicking off a publish. The `guard` is the only concurrency gate —
    /// it prevents both a second toolbar tap and `verifyAndSaveToken` from opening a second
    /// `consume` loop over the same window.
    private func start(source: URL, repoName: String) {
        guard !isRunning else { return }
        phase = .running(milestone: "Starting…")
        sheetPresented = true
        inFlight = Task {
            await self.consume(
                bootstrap.publish(source: source, repoName: repoName, isPrivate: true),
                source: source,
                repoName: repoName
            )
        }
    }

    private func consume(_ stream: AsyncStream<RepoBootstrap.Event>, source: URL, repoName: String) async {
        for await event in stream {
            switch event {
            case .progress(_, let message): phase = .running(milestone: message)
            case .needsAuth:
                phase = .needsAuth
                pendingPublish = (source, repoName)
                tokenVerification = .idle
                tokenPromptPresented = true
                sheetPresented = false
            case .published(let repo):
                phase = .published(repo)
                existingRemote = repo
            case .failed(let reason):
                phase = .failed(reason: reason)
            }
        }
        // If the task was cancelled without a terminal event, the stream finishes while phase is
        // still .running — reset so isRunning clears and the toolbar button re-enables.
        if case .running = phase { phase = .idle }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build --target AnglesiteAppCore
```
Expected: clean build. (`SiteWindow.swift`'s reference to the old `authSheetPresented`/`authCompleted` names lives inside the still-dead `#if !ANGLESITE_MAS` block, so this rename doesn't break compilation yet — Task 5 fixes that reference when it un-gates the block.)

- [ ] **Step 3: Run the full test suite as a regression check**

```bash
swift test --package-path .
```
Expected: PASS (no existing test references `PublishModel`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/PublishModel.swift
git commit -m "feat(app): rework PublishModel's needsAuth handling around a token prompt (#654)

Replaces authSheetPresented/authCompleted (which pointed at the now-
deleted gh-CLI auth sheet) with tokenPromptPresented/verifyAndSaveToken,
mirroring DeployModel's existing blocked-on-missing-token pattern."
```

---

### Task 4: `GitHubTokenPromptView`

**Files:**
- Create: `Sources/AnglesiteApp/GitHubTokenPromptView.swift`

**Interfaces:**
- Consumes: `PublishModel.tokenVerification`, `PublishModel.verifyAndSaveToken(_:)` (Task 3).
- Produces: `GitHubTokenPromptView` (SwiftUI `View`, `init(model: PublishModel, onCancel: () -> Void)`). Task 5 wires this into `SiteWindow.swift`.

- [ ] **Step 1: Create the view**

Create `Sources/AnglesiteApp/GitHubTokenPromptView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Publish-blocked modal: guide the user through creating a GitHub personal access token, verify
/// it against GitHub, store it in the Keychain, and let the parked publish proceed. Surfaced by
/// `PublishModel` when `RepoBootstrap` reports `.needsAuth` — i.e. no token is in the Keychain yet.
///
/// Modeled directly on `CloudflareTokenPromptView`. GitHub has no token-template pre-fill (unlike
/// Cloudflare's `AnglesiteTokenTemplate`), so there's a single numbered step rather than three.
///
/// The view only onboards the token. Long-term management (replacing, clearing) happens in
/// Settings → Advanced → Credentials, which shares the same Keychain slot (`SecretAccounts.gitHubToken`),
/// so a token saved from either entry point is immediately usable here and there.
struct GitHubTokenPromptView: View {
    let model: PublishModel
    let onCancel: () -> Void

    @State private var token: String = ""
    @FocusState private var fieldFocused: Bool

    /// True once a verification is in flight (`.checking`) and during the brief success flash
    /// (`.connected`) — i.e. whenever the field and submit button should be locked so the user
    /// can't edit or re-submit mid-verify.
    private var isInputLocked: Bool {
        switch model.tokenVerification {
        case .checking, .connected: return true
        case .idle, .failed: return false
        }
    }

    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInputLocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to GitHub")
                    .font(.headline)
                Text("Publishing needs a one-time personal access token. It takes about a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1) {
                    Link(destination: URL(string: "https://github.com/settings/tokens?type=beta")!) {
                        Label("Open GitHub personal access tokens", systemImage: "arrow.up.forward.app")
                    }
                }
                step(2) {
                    Text("Create a fine-grained token with **Contents: Read and write** access, then copy it and paste it below.")
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("Personal access token", text: $token, prompt: Text("paste token"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .disabled(isInputLocked)
                .onSubmit { submit() }

            status
                .frame(minHeight: 16, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect & publish") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { fieldFocused = true }
    }

    /// A numbered step: a right-aligned plain digit followed by its content.
    @ViewBuilder
    private func step(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.tokenVerification {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking token…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        case .connected(let accountLogin):
            Label(
                accountLogin.map { "Connected to \($0)" } ?? "Token verified",
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.verifyAndSaveToken(token) }
    }
}

#Preview {
    GitHubTokenPromptView(model: PublishModel(), onCancel: {})
}
```

- [ ] **Step 2: Build**

```bash
swift build --target AnglesiteAppCore
```
Expected: clean build. This file isn't referenced anywhere yet (Task 5 wires it in), but it must compile standalone — its `#Preview` alone forces full type-checking.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/GitHubTokenPromptView.swift
git commit -m "feat(app): add GitHubTokenPromptView, modeled on CloudflareTokenPromptView (#654)"
```

---

### Task 5: Un-gate the UI and wire the new token prompt

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:412-434` (toolbar item), `:531-545` (sheets)
- Modify: `Sources/AnglesiteApp/WebsiteCommands.swift:81-95` (Site ▸ GitHub menu)
- Modify: `Sources/AnglesiteApp/PublishSheet.swift` (remove file-level gate)
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:464-466` (`canPublishToGitHub`)
- Modify: `Sources/AnglesiteCore/RepoBootstrap.swift:21` (stale doc comment)

**Interfaces:**
- Consumes: `PublishModel.tokenPromptPresented`, `PublishModel.cancelTokenPrompt()` (Task 3), `GitHubTokenPromptView` (Task 4).
- Produces: nothing new — this is the task where the feature becomes reachable end-to-end for the first time.

- [ ] **Step 1: Un-gate the toolbar item in `SiteWindow.swift`**

Find (around line 412):

```swift
            #if !ANGLESITE_MAS
            // One stable item whose label/action reflects publish state — two swapping items
            // would break saved customizations.
            ToolbarItem(id: SiteToolbarItemID.github.rawValue, placement: .primaryAction) {
                if let remote = model.publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site's GitHub repository")
                } else {
                    Button {
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(!model.canPublishToGitHub)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                }
            }
            .defaultCustomization(.hidden)
            #endif
```

Replace with the same content minus the `#if !ANGLESITE_MAS`/`#endif` lines:

```swift
            // One stable item whose label/action reflects publish state — two swapping items
            // would break saved customizations.
            ToolbarItem(id: SiteToolbarItemID.github.rawValue, placement: .primaryAction) {
                if let remote = model.publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site's GitHub repository")
                } else {
                    Button {
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(!model.canPublishToGitHub)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                }
            }
            .defaultCustomization(.hidden)
```

- [ ] **Step 2: Un-gate and rewire the sheets in `SiteWindow.swift`**

Find (around line 531):

```swift
        #if !ANGLESITE_MAS
        .sheet(isPresented: $bindableModel.publish.sheetPresented) {
            PublishSheet(model: model.publish, siteName: site.name)
        }
        .sheet(isPresented: $bindableModel.publish.authSheetPresented) {
            GitHubAuthSheetView { result in
                switch result {
                case .authenticated:
                    model.publish.authCompleted(source: site.sourceDirectory, repoName: site.name)
                case .failed, .cancelled:
                    model.publish.authSheetPresented = false
                }
            }
        }
        #endif
```

Replace with:

```swift
        .sheet(isPresented: $bindableModel.publish.sheetPresented) {
            PublishSheet(model: model.publish, siteName: site.name)
        }
        .sheet(isPresented: $bindableModel.publish.tokenPromptPresented) {
            GitHubTokenPromptView(model: model.publish) {
                model.publish.cancelTokenPrompt()
            }
        }
```

- [ ] **Step 3: Un-gate the Site ▸ GitHub menu in `WebsiteCommands.swift`**

Find (around line 81):

```swift
            #if !ANGLESITE_MAS
            Menu("GitHub") {
                // Same identity swap as the toolbar: menus rebuild on every open, so a
                // state-dependent item is fine here (unlike the customizable toolbar, #519).
                if let remote = model?.publish.existingRemote {
                    Button("View on GitHub") { NSWorkspace.shared.open(remote.url) }
                } else {
                    Button("Publish to GitHub…") {
                        guard let model, let site = model.site else { return }
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    }
                    .disabled(model?.canPublishToGitHub != true)
                }
            }
            #endif
```

Replace with the same content minus the `#if !ANGLESITE_MAS`/`#endif` lines:

```swift
            Menu("GitHub") {
                // Same identity swap as the toolbar: menus rebuild on every open, so a
                // state-dependent item is fine here (unlike the customizable toolbar, #519).
                if let remote = model?.publish.existingRemote {
                    Button("View on GitHub") { NSWorkspace.shared.open(remote.url) }
                } else {
                    Button("Publish to GitHub…") {
                        guard let model, let site = model.site else { return }
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    }
                    .disabled(model?.canPublishToGitHub != true)
                }
            }
```

- [ ] **Step 4: Remove the file-level gate from `PublishSheet.swift`**

The file currently starts with `#if !ANGLESITE_MAS` (line 1) and ends with `#endif` (last line). Remove both lines, leaving the rest of the file (the `import`s and `struct PublishSheet`) unchanged. Also update the file's doc comment, which references the deleted `GitHubAuthSheetView`:

Find:
```swift
/// Progress + result for "Publish to GitHub". The auth sub-flow is a separate sheet
/// (`GitHubAuthSheetView`) presented by `SiteWindow` when the model enters `.needsAuth`.
```

Replace with:
```swift
/// Progress + result for "Publish to GitHub". The auth sub-flow is a separate sheet
/// (`GitHubTokenPromptView`) presented by `SiteWindow` when the model enters `.needsAuth`.
```

- [ ] **Step 5: Un-gate `canPublishToGitHub` in `SiteWindowModel.swift`**

Find (around line 464):

```swift
    #if !ANGLESITE_MAS
    var canPublishToGitHub: Bool { site?.isValid == true && !publish.isRunning }
    #endif
```

Replace with:

```swift
    var canPublishToGitHub: Bool { site?.isValid == true && !publish.isRunning }
```

- [ ] **Step 6: Fix the stale doc comment in `RepoBootstrap.swift`**

Find (line 21):

```swift
        /// Provider has no credentials. The UI presents `GitHubAuthSheetView`, then retries `publish`.
        case needsAuth
```

Replace with:

```swift
        /// Provider has no credentials. The UI presents a GitHub token prompt, then retries `publish`.
        case needsAuth
```

- [ ] **Step 7: Regenerate the Xcode project and build**

```bash
xcodegen generate
swift build --package-path .
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: both clean builds. This is the first time the un-gated code compiles — if `GitHubTokenPromptView`, `model.publish.tokenPromptPresented`, or `model.publish.cancelTokenPrompt()` have a typo or signature mismatch, it surfaces here.

- [ ] **Step 8: Run the full test suite**

```bash
swift test --package-path .
```
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(app): un-gate Publish to GitHub for MAS builds (#654)

Toolbar item, Site menu, and PublishSheet were compiled out via
#if !ANGLESITE_MAS, which — Anglesite now shipping MAS-only — meant
no user of the shipping app could reach this feature. Wires the new
GitHubTokenPromptView (replacing the deleted gh-CLI auth sheet) into
the .needsAuth path."
```

---

### Task 6: Manual smoke verification

**Files:** none (verification only).

Per `CONTRIBUTING.md`, UI changes need a real build/click-test — type checking and unit tests verify code correctness, not feature correctness. Run this in Xcode with a Debug build.

- [ ] **Step 1: Open the project and confirm the UI is visible**

```bash
open Anglesite.xcodeproj
```
Build and run (⌘R). Open or create a site. Confirm:
- The toolbar shows a "Publish to GitHub" button (not absent).
- Site ▸ GitHub menu exists with "Publish to GitHub…".
- Settings ▸ Advanced ▸ Credentials shows exactly one GitHub row (the `KeychainTokenRow`, no "Connect…" gh-based row).

- [ ] **Step 2: Exercise the no-token path**

Ensure no GitHub token is currently stored (Settings ▸ Advanced ▸ Credentials ▸ GitHub row ▸ Clear, if one is present from prior testing). Click "Publish to GitHub" on a valid site. Confirm:
- `GitHubTokenPromptView` appears (not a progress spinner stuck forever).
- Pasting an invalid/garbage token and clicking "Connect & publish" shows an inline red error and the prompt stays open.
- Pasting a real fine-grained PAT (Contents: read/write) shows "Connected to `<login>`" briefly, then the prompt dismisses and `PublishSheet` takes over automatically (no second click needed).

- [ ] **Step 3: Confirm the publish completes**

Confirm `PublishSheet` reaches "Published to GitHub" with a working link, and that the toolbar button and Site ▸ GitHub menu now show "View on GitHub" instead of "Publish to GitHub". Click it and confirm it opens the new repo in the browser.

- [ ] **Step 4: Confirm the already-authenticated path**

With a token now stored, create a second site and click "Publish to GitHub". Confirm it runs straight through (init → commit → repo created → pushed) without the token prompt appearing again.

- [ ] **Step 5: Report results**

If any step fails, stop and fix the underlying code (don't silently work around it) before considering this plan complete. If all steps pass, the plan is done — #654's acceptance criteria are met.
