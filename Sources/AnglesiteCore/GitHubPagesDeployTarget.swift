import Foundation

/// The GitHub Pages `DeployTarget` conformer (#1015 slice 2b) — the second static host beyond
/// `CloudflareDeployTarget`, riding the plumbing slice 2a added: `HTTPGitHubClient.createRepo`/
/// `.enablePages`, `DeployStep.githubPagesPublish`, and `DomainConfig.githubPages`. Structurally
/// mirrors `CloudflareDeployTarget`'s injected-closure seam for its credential source, but has no
/// equivalent of Cloudflare's worker-name-conflict/domain-config-drift pre-checks — GitHub Pages
/// repo creation is idempotent per site (`publish` reuses whatever `githubPages` already names)
/// rather than needing a fail-fast collision guard.
public struct GitHubPagesDeployTarget: DeployTarget {
    public static let id = "githubPages"

    /// Returns the GitHub personal access token, or `nil` if none is configured. Production
    /// callers use `GitHubPagesDeployTarget.keychainTokenSource` (the same Keychain slot
    /// `InProcessGit`/`HTTPRepoProvider` share); tests inject a closure returning a literal.
    public typealias TokenSource = @Sendable () async throws -> String?

    /// The token seam this target was constructed with, exposed like `CloudflareDeployTarget
    /// .tokenSource` in case a future caller needs to forward the exact same seam elsewhere.
    public let tokenSource: TokenSource
    private let client: HTTPGitHubClient

    /// Both dependencies are injectable seams with production defaults, so tests can drive a full
    /// deploy — credential gate, repo creation, Pages enablement, publish — with a literal token
    /// and a mocked transport, never touching the network.
    public init(
        tokenSource: @escaping TokenSource = GitHubPagesDeployTarget.keychainTokenSource,
        client: HTTPGitHubClient = HTTPGitHubClient()
    ) {
        self.tokenSource = tokenSource
        self.client = client
    }

    // MARK: DeployTarget

    /// Pre-build gate: token resolution only — no network call belongs here, matching
    /// `CloudflareDeployTarget.authorize`'s "fail-fast, not fail-first" posture. Repo
    /// creation/Pages enablement (which do call the network) happen in `publish`, not here.
    public func authorize(siteDirectory: URL) async -> DeployTargetAuthorization {
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .blocked(.failed(reason: "couldn't read GitHub token: \(error)", exitCode: nil))
        }
        guard let token, !token.isEmpty else {
            return .blocked(.failed(
                reason: "no GitHub token — add one in Settings → Advanced → Credentials",
                exitCode: nil))
        }
        return .ready(credential: token)
    }

    /// Provisions the dedicated Pages repo on first deploy (or reuses the one already declared in
    /// `anglesite.json`), then runs `.githubPagesPublish` through the executor and reports the
    /// resulting `https://<owner>.github.io/<repo>/` URL.
    public func publish(context: DeployTargetContext) async -> DeployCommand.Result {
        let declared = (try? DomainConfigStore(sourceDirectory: context.siteDirectory).load())?.githubPages

        let owner: String
        let repo: String
        if let declaredOwner = declared?.owner, !declaredOwner.isEmpty,
           let declaredRepo = declared?.repo, !declaredRepo.isEmpty {
            owner = declaredOwner
            repo = declaredRepo
        } else {
            switch await provisionRepo(
                siteDirectory: context.siteDirectory, siteID: context.siteID, token: context.credential
            ) {
            case .failure(let result):
                return result
            case .success(let created):
                owner = created.owner
                repo = created.name
                DomainConfigStore.update(sourceDirectory: context.siteDirectory) {
                    $0.githubPages = DomainConfig.GitHubPages(owner: owner, repo: repo)
                }
            }
        }

        var environment = context.baseEnvironment
        environment["GITHUB_PAGES_TOKEN"] = context.credential

        let started = Date()
        context.onProgress?(.deployDeploying)
        let publishResult = await context.executor.run(
            step: .githubPagesPublish,
            siteDirectory: context.siteDirectory,
            environment: environment,
            source: "deploy:\(context.siteID)"
        )
        let duration = Date().timeIntervalSince(started)
        if !Task.isCancelled { context.onProgress?(.deployFinalizing) }

        guard let code = publishResult.exitCode else {
            // nil exit code → unavailable resolver, spawn failure, or termination (e.g.
            // cancellation) — matches `CloudflareDeployTarget.publish`'s handling exactly.
            if Task.isCancelled {
                return .failed(reason: "GitHub Pages publish was terminated", exitCode: nil)
            }
            return .failed(
                reason: publishResult.output.isEmpty ? "GitHub Pages publish was terminated" : publishResult.output,
                exitCode: nil)
        }
        guard code == 0 else {
            return .failed(reason: "GitHub Pages publish exited with code \(code)", exitCode: code)
        }
        guard let url = URL(string: "https://\(owner).github.io/\(repo)/") else {
            return .failed(
                reason: "GitHub Pages published successfully, but the site URL could not be constructed",
                exitCode: 0)
        }
        return .succeeded(url: url, duration: duration)
    }

    // MARK: Repo provisioning

    private enum ProvisionOutcome {
        case success(RemoteRepo)
        case failure(DeployCommand.Result)
    }

    /// Creates the dedicated public Pages repo and enables Pages on it, once. Public — see the
    /// design doc's owner decision — because GitHub Pages on a private repo needs a paid plan and
    /// this target exists to be the unencumbered second host.
    private func provisionRepo(siteDirectory: URL, siteID: String, token: String) async -> ProvisionOutcome {
        let name = Self.candidateRepoName(siteDirectory: siteDirectory, siteID: siteID)
        let created: RemoteRepo
        do {
            created = try await client.createRepo(name: name, isPrivate: false, token: token)
        } catch let apiError as GitHubRepoAPIError {
            return .failure(.failed(reason: Self.message(for: apiError), exitCode: nil))
        } catch {
            return .failure(.failed(reason: "couldn't create GitHub Pages repo: \(error)", exitCode: nil))
        }
        do {
            try await client.enablePages(owner: created.owner, repo: created.name, token: token)
        } catch let apiError as GitHubRepoAPIError {
            return .failure(.failed(reason: Self.message(for: apiError), exitCode: nil))
        } catch {
            return .failure(.failed(reason: "couldn't enable GitHub Pages: \(error)", exitCode: nil))
        }
        return .success(created)
    }

    /// The candidate name for a freshly-created Pages repo: `.site-config`'s `CF_PROJECT_NAME` —
    /// the same slugified project name already used for the site's Cloudflare Worker — or, absent
    /// that (a site that has never touched the Cloudflare path), `siteID` itself, which is always
    /// present, stable across retries, and already GitHub-repo-name-safe (a UUID string).
    private static func candidateRepoName(siteDirectory: URL, siteID: String) -> String {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if let projectName = SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config), !projectName.isEmpty {
            return projectName
        }
        return siteID
    }

    private static func message(for error: GitHubRepoAPIError) -> String {
        switch error {
        case .network: return "couldn't reach GitHub — check your connection and try again"
        case .unauthorized: return "GitHub rejected the token — update it in Settings → Advanced → Credentials"
        case .nameAlreadyExists: return "a repository with that name already exists on your GitHub account"
        case .http(let status): return "GitHub returned an unexpected error (HTTP \(status))"
        case .api(let message): return message
        case .malformedResponse: return "GitHub returned an unexpected response"
        }
    }

    // MARK: Default seams

    /// Default `TokenSource` for production: the app-owned Keychain slot, matching
    /// `InProcessGit.defaultTokenProvider`/`HTTPRepoProvider`'s default exactly — Settings →
    /// Advanced → Credentials and the in-process git push path all share this one slot.
    public static let keychainTokenSource: TokenSource = {
        try PlatformSecretStore.make().readGitHubToken()
    }
}
