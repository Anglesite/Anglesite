import Foundation

/// Pushes a `SocialWorkerProvisionCommand`-provisioned Cloudflare Worker secret inside a running
/// container via `LocalContainerControl.exec`. Ordinary wrangler subcommands (`d1`/`kv`/`r2
/// create`, `d1 migrations apply`, …) no longer go through this type — `SocialWorkerProvisionTarget.publish`
/// runs those through `context.executor.run(step: .wranglerSubcommand(args:), …)` instead, the
/// same `DeployExecutor` seam (`ContainerDeployExecutor`, `DeployExecutor.swift:61-168`) the three
/// fixed deploy steps use — so only the secret-push seam (which `DeployExecutor` has no step for)
/// remains here.
public struct ContainerCommandRunner: Sendable {
    private let control: any LocalContainerControl
    private let siteID: String
    private let configDirectory: URL
    private let logCenter: LogCenter

    /// Creates a runner bound to `siteID`'s already-running container. `configDirectory` is the
    /// site package's `Config/`, whose `wrangler.toml` is staged into the guest before `wrangler
    /// secret put` (#1960). Every line of command output streams into `logCenter` (default: the
    /// shared debug-pane log — logs are sacred, so provisioning output is never dropped even
    /// though callers only see the final result).
    public init(control: any LocalContainerControl, siteID: String, configDirectory: URL, logCenter: LogCenter = .shared) {
        self.control = control
        self.siteID = siteID
        self.configDirectory = configDirectory
        self.logCenter = logCenter
    }

    /// Bind this instance's secret-push as a `SocialWorkerProvisionCommand.SecretRunner` closure.
    public var secretRunner: SocialWorkerProvisionCommand.SecretRunner {
        { [self] siteDirectory, name, value, environment, source in
            try await self.runSecret(siteDirectory: siteDirectory, name: name, value: value, environment: environment, source: source)
        }
    }

    /// Pushes `value` as the named Cloudflare Worker secret. `wrangler secret put <NAME>` reads
    /// its value from stdin, which `exec` (one-shot, no stdin plumbing) can't supply directly —
    /// instead this runs a tiny in-guest shell script that reads the value from an environment
    /// variable and pipes it in itself, so the secret's actual bytes never appear in `argv` or in
    /// the script text (only the two fixed variable *names* do). `name` and `value` are passed
    /// via the same `environment` allowlist mechanism `CLOUDFLARE_API_TOKEN` already uses — this
    /// call's environment additions are scoped to this one invocation, never merged into the
    /// broader allowlist set other wrangler calls share.
    private func runSecret(
        siteDirectory: URL,
        name: String,
        value: String,
        environment: [String: String],
        source: String
    ) async throws -> ProcessSupervisor.RunResult {
        // `wrangler secret put` resolves the Worker's name from `wrangler.toml` in the working
        // directory, and the guest's clone of `Source/` no longer carries one (#1960) — stage the
        // host package's `Config/wrangler.toml` first, exactly as `ContainerDeployExecutor` does
        // before `wrangler deploy`. A site with no config yet has nothing to stage; wrangler then
        // reports the missing name itself.
        if let stagingArgv = WranglerInvocation.configStagingArgv(configDirectory: configDirectory) {
            let staged = try await control.exec(
                siteID: siteID, argv: stagingArgv, environment: [:],
                workingDirectory: "/workspace/site", onOutput: { _, _ in })
            guard staged.exitCode == 0 else {
                return ProcessSupervisor.RunResult(
                    stdout: "", stderr: "couldn't sync wrangler.toml into the container (exit \(staged.exitCode))",
                    exitCode: staged.exitCode)
            }
        }
        var guestEnvironment = WranglerInvocation.guestEnvironment(from: environment, scope: .tokenOnly)
        guestEnvironment["WRANGLER_SECRET_NAME"] = name
        guestEnvironment["WRANGLER_SECRET_VALUE"] = value
        let argv = [
            "sh", "-c",
            "printf '%s' \"$WRANGLER_SECRET_VALUE\" | npx wrangler secret put \"$WRANGLER_SECRET_NAME\"",
        ]
        let result = try await WranglerInvocation.exec(
            control: control, siteID: siteID, argv: argv, environment: guestEnvironment,
            logCenter: logCenter, source: source)
        return ProcessSupervisor.RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}
