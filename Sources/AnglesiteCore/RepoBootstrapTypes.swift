import Foundation

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
    ///
    /// - Parameter hostName: The remote URL's host, e.g. `"github.com"` or `"artifacts.cloudflare.com"`.
    ///   Matched case-insensitively.
    /// - Returns: The matching provider, or nil when `hostName` isn't recognized.
    public static func match(hostName: String) -> RepoHost? {
        switch hostName.lowercased() {
        case "github.com", "www.github.com": .github
        case artifactsHostName: .cloudflareArtifacts
        default: nil
        }
    }

    /// Browser URL for a repo on this host (no `.git` suffix).
    ///
    /// - Parameters:
    ///   - owner: The GitHub account/organization, or Cloudflare account ID, that owns the repo.
    ///   - name: The repository name, with any `.git` suffix already stripped.
    /// - Returns: The browser URL, or nil if `owner`/`name` can't form a valid URL.
    public func browseURL(owner: String, name: String) -> URL? {
        switch self {
        case .github: URL(string: "https://github.com/\(owner)/\(name)")
        case .cloudflareArtifacts: URL(string: "https://\(Self.artifactsHostName)/\(owner)/\(name)")
        }
    }
}

/// A site's git remote (GitHub or Cloudflare Artifacts), derived from `origin`. Source of truth for "is this site published?".
public struct RemoteRepo: Sendable, Equatable {
    /// Browser URL, e.g. `https://github.com/owner/name` — always https, regardless of whether
    /// the remote itself was an ssh URL.
    public let url: URL
    /// The GitHub account or organization owning the repository.
    public let owner: String
    /// The repository name, with any `.git` suffix already stripped.
    public let name: String
    /// Which provider hosts this remote — derived from the host in `parse(remoteURL:)`.
    public let host: RepoHost

    /// Memberwise initializer; prefer ``parse(remoteURL:)``, which derives all three fields
    /// consistently from a raw remote URL.
    public init(url: URL, owner: String, name: String, host: RepoHost = .github) {
        self.url = url
        self.owner = owner
        self.name = name
        self.host = host
    }

    /// Parse a git remote URL (https or scp-like ssh) into owner/name + a browser URL.
    /// Returns nil for empty/unparseable input or hosts `RepoHost` doesn't recognize.
    public static func parse(remoteURL raw: String) -> RemoteRepo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var owner = "", name = "", host = ""
        if trimmed.hasPrefix("git@") || (!trimmed.contains("://") && trimmed.contains(":")) {
            // scp-like: git@github.com:owner/name.git — host is between "@" and ":"
            guard let at = trimmed.firstIndex(of: "@"), let colon = trimmed.firstIndex(of: ":") else { return nil }
            // A ":" before the "@" (e.g. "host:user@path") would make the host range start > end
            // and trap on the subscript. Reject rather than crash.
            guard at < colon else { return nil }
            host = String(trimmed[trimmed.index(after: at)..<colon])
            let path = trimmed[trimmed.index(after: colon)...].split(separator: "/")
            guard path.count >= 2 else { return nil }
            owner = String(path[path.count - 2])
            name = String(path[path.count - 1])
        } else if let u = URL(string: trimmed), let urlHost = u.host {
            host = urlHost
            let comps = u.path.split(separator: "/")
            guard comps.count >= 2 else { return nil }
            owner = String(comps[comps.count - 2])
            name = String(comps[comps.count - 1])
        } else {
            return nil
        }

        guard let repoHost = RepoHost.match(hostName: host) else { return nil }

        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty, let browse = repoHost.browseURL(owner: owner, name: name) else {
            return nil
        }
        return RemoteRepo(url: browse, owner: owner, name: name, host: repoHost)
    }
}

/// User-facing failure from the bootstrap pipeline.
public struct RepoBootstrapError: LocalizedError, Equatable, Sendable {
    /// The user-facing explanation — written for the site owner (what went wrong and what to do),
    /// not as a git diagnostic. Surfaced verbatim via `RepoBootstrap.Event.failed`.
    public let reason: String
    /// Wraps a user-facing failure message.
    public init(reason: String) { self.reason = reason }
    /// `LocalizedError` conformance so `error.localizedDescription` shows `reason` rather than a
    /// generic "operation couldn't be completed".
    public var errorDescription: String? { reason }
}

/// Run a subprocess and capture its output. Production: `ProcessSupervisor.shared.run`.
public typealias RepoCommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult

/// Creates the remote repository and pushes to it. Git-side preflight lives in `RepoBootstrap`,
/// not here.
public protocol RepoProvider: Sendable {
    /// True if the provider has usable credentials (no interactive prompt needed).
    func isAuthenticated() async -> Bool
    /// Create the remote repo, wire `origin` in `source`, and push. Throws `RepoBootstrapError`.
    func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo
}

/// GitHub provider backed by the `gh` CLI. Reuses `gh`'s credential store (per CLAUDE.md the app
/// does not own GitHub creds). The App Store UI compiles this path out.
public struct GHRepoProvider: RepoProvider {
    private let run: RepoCommandRunner
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    /// Creates a provider that runs `gh`/`git` through the given runner — injectable so tests can
    /// script subprocess results without spawning anything.
    public init(run: @escaping RepoCommandRunner) { self.run = run }

    /// True when `gh auth status` exits 0 — i.e. the user's own `gh` login is usable. No token is
    /// read or stored app-side.
    public func isAuthenticated() async -> Bool {
        guard let r = try? await run(env, ["gh", "auth", "status"], nil) else { return false }
        return r.exitCode == 0
    }

    /// `gh repo create --source … --push` in one shot, then reads `origin` back as the source of
    /// truth rather than parsing `gh`'s human-oriented output. Throws ``RepoBootstrapError`` with
    /// the first non-empty stderr line so the owner sees `gh`'s own explanation (name taken,
    /// scope missing, …).
    public func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
        let visibility = isPrivate ? "--private" : "--public"
        // `--` terminates flag parsing, so `name` (the positional) must come last, after all flags —
        // it guards a future caller passing a leading-hyphen name from having it read as a flag.
        // (`gh repo create -- name --private` is rejected by gh; the terminator must follow the flags.)
        let create = try await run(env,
            ["gh", "repo", "create", visibility,
             "--source", source.path(percentEncoded: false), "--remote", "origin", "--push", "--", name],
            source)
        guard create.exitCode == 0 else {
            throw RepoBootstrapError(reason: Self.firstLine(create.stderr) ?? "Couldn't create the GitHub repository.")
        }
        // origin is now set; read it back as the source of truth rather than parsing gh's output.
        let originRead = try await run(env, ["git", "remote", "get-url", "origin"], source)
        guard originRead.exitCode == 0, let repo = RemoteRepo.parse(remoteURL: originRead.stdout) else {
            throw RepoBootstrapError(reason: "Repository created, but couldn't read its origin URL.")
        }
        return repo
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
