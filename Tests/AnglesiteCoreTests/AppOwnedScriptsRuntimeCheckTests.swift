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
}
