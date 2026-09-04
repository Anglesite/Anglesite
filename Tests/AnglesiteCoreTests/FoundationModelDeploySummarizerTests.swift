import Foundation
import Testing
@testable import AnglesiteCore

// FoundationModels is absent on the CI runner; these only compile/run under Xcode 27.
#if compiler(>=6.4) && canImport(FoundationModels)
@Suite struct FoundationModelDeploySummarizerTests {
    @Test func promptIncludesTheLog() {
        let prompt = FoundationModelDeploySummarizer.prompt(for: "✘ [ERROR] Could not resolve \"./x\"")
        #expect(prompt.contains("Could not resolve"))
        #expect(prompt.lowercased().contains("deploy"))
    }

    // Regression coverage for #1855: the prompt must call out the terminal error as the
    // authoritative cause, separate from (and ahead of) the full log's earlier warning noise.
    @Test func promptHighlightsTerminalErrorSeparatelyFromEarlierWarnings() {
        let log = """
        [WARN] [glob-loader] The base directory "src/content/members/" does not exist.
        ✘ ERROR  Failed to automatically retrieve account IDs for the logged in user.
        """
        let prompt = FoundationModelDeploySummarizer.prompt(for: log)
        #expect(prompt.contains("terminal error"))
        #expect(prompt.contains("Prioritize"))
        #expect(prompt.contains("Failed to automatically retrieve account IDs"))
    }

    @Test func promptHedgesWhenNoTerminalErrorIsFound() {
        let prompt = FoundationModelDeploySummarizer.prompt(for: "Publishing to Cloudflare...")
        #expect(prompt.contains("not certain"))
    }

    @Test func emptyLogReturnsNilWithoutModel() async {
        // Whitespace-only log must short-circuit to nil and never invoke the on-device model,
        // so this is deterministic on machines with or without Apple Intelligence.
        let result = await FoundationModelDeploySummarizer().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
#endif

@Suite struct DeploySummarizerFactoryTests {
    // A whitespace-only log returns nil on both toolchains, for different reasons: under Xcode 27
    // the real conformer short-circuits before any model call; on CI the Noop returns nil for any
    // input. Either way the assertion holds everywhere and never invokes Apple Intelligence.
    @Test func makeDefaultProductReturnsNilForEmptyLog() async {
        let result = await DeploySummarizerFactory.makeDefault().summarize(
            failureLog: "   ", siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp/s")
        )
        #expect(result == nil)
    }
}
