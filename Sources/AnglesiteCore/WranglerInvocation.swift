import Foundation

/// The one place that builds `npx wrangler` argv, resolves which secrets a wrangler call may see
/// in-guest, and runs the exec-and-drain-to-`LogCenter` loop shared by every `wrangler` call site
/// (`ContainerCommandRunner`, `ContainerDeployExecutor`) — see #1821.
public enum WranglerInvocation {
    /// Which Cloudflare secrets a wrangler call may see in-guest. `.tokenOnly` matches
    /// `SocialWorkerProvisionCommand`'s resource-creation/secret-push/migration calls (today's
    /// `ContainerCommandRunner.guestEnvAllowlist`); `.tokenAndAccount` matches the fixed
    /// `.wrangler`/`.bundleUpload` deploy steps (today's `ContainerDeployExecutor
    /// .guestEnvAllowlist`), which also need `CLOUDFLARE_ACCOUNT_ID` (#1853).
    public enum EnvScope: Sendable {
        case tokenOnly
        case tokenAndAccount
    }

    /// `["npx", "wrangler"] + subcommand` — the argv every plain (non-shell-wrapped) wrangler
    /// invocation shares.
    public static func argv(subcommand: [String]) -> [String] {
        ["npx", "wrangler"] + subcommand
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
