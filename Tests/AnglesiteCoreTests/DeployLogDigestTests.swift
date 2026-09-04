import Testing
@testable import AnglesiteCore

@Suite struct DeployLogDigestTests {
    @Test func dropsBuildNoiseKeepsError() {
        let raw = """
        > astro build
        npm run build
        vite v5.0 building for production...
        ✓ 42 modules transformed
        Publishing to Cloudflare...
        ✘ [ERROR] Could not resolve "./missing"
        """
        let digest = DeployLogDigest.extract(from: raw)
        #expect(digest.contains("Could not resolve"))
        #expect(digest.contains("Publishing to Cloudflare"))
        #expect(!digest.contains("astro build"))
        #expect(!digest.contains("npm run build"))
        #expect(!digest.contains("modules transformed"))
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(DeployLogDigest.extract(from: "   \n  ").isEmpty)
    }

    @Test func capsToTail() {
        let long = String(repeating: "x", count: DeployLogDigest.maxCharacters + 500)
        let digest = DeployLogDigest.extract(from: long)
        #expect(digest.count == DeployLogDigest.maxCharacters)
        #expect(digest == String(long.suffix(DeployLogDigest.maxCharacters)))
    }

    @Test func keepsWranglerURLAndVersionLines() {
        let raw = """
        > astro build
        > https://my-worker.username.workers.dev
        > 1.2.3 deployed
        > {"success":true}
        ✘ [ERROR] deploy failed
        """
        let digest = DeployLogDigest.extract(from: raw)
        #expect(!digest.contains("astro build"))
        #expect(digest.contains("https://my-worker.username.workers.dev"))
        #expect(digest.contains("1.2.3 deployed"))
        #expect(digest.contains("{\"success\":true}"))
    }

    // Regression coverage for #1855: the on-device summary latched onto Astro's informational
    // content-glob warnings instead of the terminal wrangler error that actually failed the
    // deploy. `terminalError` must isolate the real failure and ignore the warning noise above it.
    @Test func terminalErrorIgnoresEarlierWarningsAndFindsWranglerFailure() {
        let raw = """
        [WARN] [glob-loader] The base directory "src/content/members/" does not exist.
        [WARN] [glob-loader] The base directory "src/content/blogroll/" does not exist.
        Publishing to Cloudflare...
        ✘ ERROR  Failed to automatically retrieve account IDs for the logged in user.
          You may have incorrect permissions on your API token.
        """
        let terminal = DeployLogDigest.terminalError(in: raw)
        #expect(terminal != nil)
        #expect(terminal?.contains("Failed to automatically retrieve account IDs") == true)
        #expect(terminal?.contains("incorrect permissions") == true)
        #expect(terminal?.contains("glob-loader") == false)
    }

    @Test func terminalErrorMatchesNpmErrPrefix() {
        let raw = """
        Publishing to Cloudflare...
        npm ERR! code ENOENT
        npm ERR! syscall open
        """
        let terminal = DeployLogDigest.terminalError(in: raw)
        #expect(terminal?.contains("npm ERR! code ENOENT") == true)
    }

    @Test func terminalErrorMatchesErrorColonPrefix() {
        let raw = """
        Publishing to Cloudflare...
        Error: could not authenticate with Cloudflare
        """
        let terminal = DeployLogDigest.terminalError(in: raw)
        #expect(terminal == "Error: could not authenticate with Cloudflare")
    }

    @Test func terminalErrorReturnsNilWhenNoErrorLinePresent() {
        let raw = """
        [WARN] [glob-loader] The base directory "src/content/members/" does not exist.
        Publishing to Cloudflare...
        """
        #expect(DeployLogDigest.terminalError(in: raw) == nil)
    }

    @Test func terminalErrorDoesNotMatchLowercaseErrorInsideProse() {
        // A word like "errors" appearing mid-sentence in a warning must not be mistaken for a
        // real failure — only an uppercase "ERROR" token, "✘", "npm ERR!", or "Error:" count.
        let raw = "This step reports zero errors and completed successfully."
        #expect(DeployLogDigest.terminalError(in: raw) == nil)
    }
}
