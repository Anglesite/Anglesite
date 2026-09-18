import Foundation

/// The one place that builds `npx wrangler` argv, resolves which secrets a wrangler call may see
/// in-guest, and runs the exec-and-drain-to-`LogCenter` loop shared by every `wrangler` call site
/// (`ContainerCommandRunner`, `ContainerDeployExecutor`) — see #1821.
public enum WranglerInvocation {
    /// Which Cloudflare secrets a wrangler call may see in-guest — the single source of truth
    /// every wrangler call site (`ContainerCommandRunner`'s resource-creation/secret-push/
    /// migration calls, and `ContainerDeployExecutor`'s `.wrangler`/`.bundleUpload`/
    /// `.wranglerSubcommand` steps) delegates to via `guestEnvironment(from:scope:)` below,
    /// rather than each re-declaring its own allowlist. `.tokenOnly` covers the arbitrary
    /// provisioning subcommands; `.tokenAndAccount` covers `.wrangler`/`.bundleUpload`, which also
    /// need `CLOUDFLARE_ACCOUNT_ID` (#1853).
    public enum EnvScope: Sendable {
        case tokenOnly
        case tokenAndAccount
    }

    /// `["npx", "wrangler"] + subcommand` — the argv every plain (non-shell-wrapped) wrangler
    /// invocation shares.
    public static func argv(subcommand: [String]) -> [String] {
        ["npx", "wrangler"] + subcommand
    }

    /// The guest shell argv that overwrites `wrangler.toml` in the guest's current working
    /// directory with the host package's current `Config/wrangler.toml` (#1084, #1960) — `nil`
    /// when the host has no file yet (a site that has never been scaffolded for deploy), meaning
    /// there's nothing to stage. Base64-encodes the content so it embeds directly in the `sh -c`
    /// string with no shell-quoting/escaping surface, mirroring
    /// `ContainerizationControl.writeGuestFile`. Callers run this before every wrangler
    /// invocation that reads configuration — `deploy`, `secret put`, `d1 migrations apply` —
    /// because the guest's clone of `Source/` carries no `wrangler.toml` at all.
    public static func configStagingArgv(configDirectory: URL) -> [String]? {
        guard let contents = WranglerConfigFile.read(configDirectory: configDirectory) else { return nil }
        let encoded = Data(contents.utf8).base64EncodedString()
        return ["sh", "-c", "echo \(encoded) | base64 -d > \(WranglerConfigFile.filename)"]
    }

    /// Filters `environment` down to the keys `scope` allows across the host→guest boundary.
    public static func guestEnvironment(from environment: [String: String], scope: EnvScope) -> [String: String] {
        let allowlist: Set<String> = {
            switch scope {
            case .tokenOnly: return ["CLOUDFLARE_API_TOKEN"]
            case .tokenAndAccount: return ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]
            }
        }()
        return environment.filter { allowlist.contains($0.key) }
    }

    /// Runs `argv` in `siteID`'s container via `control.exec`, streaming stdout/stderr into
    /// `logCenter` under `source` line-by-line as it arrives, draining fully on every exit path
    /// (success or thrown error) before returning/rethrowing — the same drain discipline
    /// `ContainerDeployExecutor.run` already documents (never leak a buffered line, never leave
    /// the drain task still running when this function returns).
    public static func exec(
        control: any LocalContainerControl,
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String = "/workspace/site",
        logCenter: LogCenter,
        source: String
    ) async throws -> ContainerExecResult {
        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        let drain = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }
        do {
            let result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: environment,
                workingDirectory: workingDirectory,
                onOutput: { line, stream in continuation.yield((line, stream)) }
            )
            continuation.finish()
            _ = await drain.value
            return result
        } catch {
            continuation.finish()
            _ = await drain.value
            throw error
        }
    }
}
