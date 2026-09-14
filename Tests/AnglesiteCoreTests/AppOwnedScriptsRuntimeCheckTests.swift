import Testing
import Foundation
@testable import AnglesiteCore

/// #1958: the container executor's half of the gate — how it asks the guest for digests, how it
/// reads the answer, and how it writes a restore into the guest without ever splicing a path or
/// file body into shell text.
@Suite struct AppOwnedScriptsRuntimeCheckTests {
    @Test func digestArgvPassesEveryPathAsItsOwnWordAfterTheOptionTerminator() {
        let argv = ContainerDeployExecutor.appOwnedScriptsDigestArgv(
            relativePaths: ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"])
        #expect(argv == ["sha256sum", "--", "scripts/pre-deploy-check.ts", "src/lib/rsl.ts"])
    }

    @Test func sha256sumOutputIsParsedPerRequestedPathWithMissingOnesNil() {
        let stdout = """
        0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  scripts/pre-deploy-check.ts
        FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210 *src/lib/rsl.ts
        sha256sum: src/lib/gone.ts: No such file or directory
        """
        let digests = ContainerDeployExecutor.parseAppOwnedScriptsDigests(
            stdout, relativePaths: ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts", "src/lib/gone.ts"])
        #expect(digests["scripts/pre-deploy-check.ts"] == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(digests["src/lib/rsl.ts"] == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
        #expect(digests.keys.contains("src/lib/gone.ts"))
        #expect(digests["src/lib/gone.ts"] == .some(nil))
    }

    @Test func aLineThatIsNotADigestIsIgnoredRatherThanMisreadAsOne() {
        let stdout = "not-a-digest  scripts/pre-deploy-check.ts\n"
        let digests = ContainerDeployExecutor.parseAppOwnedScriptsDigests(stdout, relativePaths: ["scripts/pre-deploy-check.ts"])
        #expect(digests["scripts/pre-deploy-check.ts"] == .some(nil))
    }

    @Test func restoreArgvCarriesThePathAndTheBytesAsPositionalParametersOnly() {
        let pin = AppOwnedScriptsGate.Pin(
            relativePath: "scripts/it's; $(rm -rf /).ts", content: Data("export const x = 1;\n".utf8))
        let argv = ContainerDeployExecutor.appOwnedScriptsRestoreArgv(pin: pin)
        #expect(argv.count == 6)
        #expect(argv[0] == "sh" && argv[1] == "-c" && argv[3] == "sh")
        #expect(argv[4] == pin.relativePath)
        #expect(argv[5] == pin.content.base64EncodedString())
        // The script never contains the path or the bytes — only `$1`/`$2` references.
        #expect(!argv[2].contains("rm -rf"))
        #expect(!argv[2].contains(argv[5]))
        #expect(argv[2].contains("\"$1\"") && argv[2].contains("\"$2\""))
        #expect(argv[2].contains("base64 -d"))
        #expect(argv[2].contains("mkdir -p"))
    }

    @Test func theSyncArgvIsTheSameFastForwardTheRuntimeUses() {
        #expect(ContainerDeployExecutor.appOwnedScriptsSyncArgv == ["git", "pull", "-q", "--ff-only"])
    }

    @Test func aHostExecutorHasNoRuntimeCopy() {
        #expect(AppOwnedScriptsGate.RuntimeCopy(executor: HostDeployExecutor(), source: "test") == nil)
    }

    // MARK: restoreAppOwnedScripts partial failure

    /// A `LocalContainerControl` whose restore `exec`s (argv0 `"sh"`, the base64-write script) fail
    /// at a scripted call index (1-based, counting only restore calls — the `git pull` fast-forward
    /// always "succeeds" so it never advances the count); every other restore call succeeds.
    private actor ScriptedRestoreControl: LocalContainerControl {
        private var restoreCallCount = 0
        private(set) var restoreArgvCalls: [[String]] = []
        let failingCallIndex: Int?
        init(failingCallIndex: Int?) { self.failingCallIndex = failingCallIndex }

        func start(siteID: String, sourceRepo: URL, ref: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> LocalContainerSession {
            throw LocalContainerError.virtualizationUnavailable
        }
        func stop(siteID: String) async throws {}
        func exec(
            siteID: String, argv: [String], environment: [String: String], workingDirectory: String,
            onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
        ) async throws -> ContainerExecResult {
            guard argv.first == "sh" else {
                return ContainerExecResult(exitCode: 0, stdout: "", stderr: "") // the `git pull` fast-forward
            }
            restoreCallCount += 1
            restoreArgvCalls.append(argv)
            if restoreCallCount == failingCallIndex {
                return ContainerExecResult(exitCode: 1, stdout: "", stderr: "permission denied")
            }
            return ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
        }
        func execInteractive(
            siteID: String, argv: [String], environment: [String: String], workingDirectory: String,
            onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
        ) async throws -> InteractiveExecHandle {
            throw LocalContainerError.virtualizationUnavailable
        }
        func startWorkersDev(
            siteID: String, workers: [WorkerDescriptor], onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
        ) async throws -> URL {
            throw LocalContainerError.virtualizationUnavailable
        }
        func stopWorkersDev(siteID: String) async throws {}
    }

    @Test func restoreAppOwnedScriptsReportsOnlyThePathsThatActuallyLandedWhenOneExecFails() async throws {
        // #1958 review finding: the old implementation returned `false` on the first failing
        // `exec` and left later pins untried; the caller then had no way to tell an actually-fixed
        // file from one that never got attempted. The fixed version keeps trying every pin and
        // returns exactly the ones that landed.
        let control = ScriptedRestoreControl(failingCallIndex: 2)
        let executor = ContainerDeployExecutor(
            control: control, siteID: "s", configDirectory: FileManager.default.temporaryDirectory, logCenter: LogCenter())
        let pins = [
            AppOwnedScriptsGate.Pin(relativePath: "scripts/pre-deploy-check.ts", content: Data("a".utf8)),
            AppOwnedScriptsGate.Pin(relativePath: "src/lib/rsl.ts", content: Data("b".utf8)),
            AppOwnedScriptsGate.Pin(relativePath: "src/lib/licensing.ts", content: Data("c".utf8)),
        ]

        let restored = await executor.restoreAppOwnedScripts(pins, source: "test")

        #expect(restored == ["scripts/pre-deploy-check.ts", "src/lib/licensing.ts"])
        let argvCalls = await control.restoreArgvCalls
        #expect(argvCalls.count == 3, "every pin was attempted, not just the ones before the failure")
    }

    @Test func restoreAppOwnedScriptsReportsAllPathsWhenNoneFail() async throws {
        let control = ScriptedRestoreControl(failingCallIndex: nil)
        let executor = ContainerDeployExecutor(
            control: control, siteID: "s", configDirectory: FileManager.default.temporaryDirectory, logCenter: LogCenter())
        let pins = [AppOwnedScriptsGate.Pin(relativePath: "scripts/pre-deploy-check.ts", content: Data("a".utf8))]
        let restored = await executor.restoreAppOwnedScripts(pins, source: "test")
        #expect(restored == ["scripts/pre-deploy-check.ts"])
    }
}
