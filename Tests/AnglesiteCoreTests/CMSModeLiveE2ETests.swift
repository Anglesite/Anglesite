import Testing
import Foundation
@testable import AnglesiteCore

/// Live, opt-in end-to-end test for CMS mode (issue #800 Milestone C1): discovery, one-time
/// content import, create, read-back, and publish against a **real** Cloudflare-backed Micropub
/// endpoint — `MicropubClient.defaultTransport` (a plain `URLSession`), never a fake transport.
///
/// **What this does NOT exercise:** the interactive IndieAuth sign-in itself. `SiteMicropubSignIn`
/// (`Sources/AnglesiteApp/SiteMicropubSignIn.swift`) drives a real `ASWebAuthenticationSession`,
/// which presents a system window `swift test` cannot present or drive headlessly — the same
/// limitation the plan's self-review notes call out for the Mac Cloudflare sign-in already in
/// this codebase. This test instead starts from an access token obtained by performing that
/// sign-in once, out of band, and exercises every step downstream of it for real: standard
/// Micropub client discovery (``MicropubEndpointDiscovery``) against the live homepage,
/// ``MicropubContentImport/importIfNeeded(siteDirectory:configDirectory:client:registry:)``
/// against the live Worker + D1, and ``MicropubClient``'s create/source/setStatus calls. The
/// DPoP key pair used to sign requests is generated fresh here rather than reusing whatever key
/// pair the out-of-band sign-in bound the token to — see the note at its call site below for what
/// that implies about how `ANGLESITE_MICROPUB_E2E_TOKEN` needs to be prepared.
///
/// Skipped (via the `.enabled(if:)` trait) unless `ANGLESITE_MICROPUB_E2E=1` — the same
/// established convention as `MCPClientHTTPEndToEndTests`/`AppliesEditEndToEndTests`
/// (`ANGLESITE_PLUGIN_PATH`) and the container suites (`ANGLESITE_CONTAINER_TESTS`/
/// `ANGLESITE_CONTAINER_E2E`), just gating on a live remote site instead of a local sibling
/// checkout. CI never sets it, so this suite is always inert there. As of 2026-08-12 (this
/// task's landing date) no real V-3-conformant test site exists to point this at yet — see the
/// plan's Context recap — so this is deliberately a skeleton: it compiles and is ready to run
/// the moment such a site exists, but is unexercised until then. That gap is flagged here and in
/// the PR body, not silently hidden behind a suite that always skips.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E"] == "1"))
struct CMSModeLiveE2ETests {
    @Test("provisioned site: import existing content, create a new post, read it back, publish")
    func fullLoop() async throws {
        guard let siteURLString = ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E_SITE_URL"],
            let siteURL = URL(string: siteURLString),
            let accessToken = ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E_TOKEN"],
            !accessToken.isEmpty
        else {
            Issue.record(
                """
                missing/invalid ANGLESITE_MICROPUB_E2E_SITE_URL or ANGLESITE_MICROPUB_E2E_TOKEN — \
                set both (plus ANGLESITE_MICROPUB_E2E=1) to run this suite against a real site
                """
            )
            return
        }

        // 1. Standard Micropub client discovery against the live homepage — the same entry point
        //    the iOS onboarding flow (#868) and the Mac sign-in sheet use, never a hardcoded path.
        let endpoints = try await MicropubEndpointDiscovery().discover(siteURL: siteURL)

        // 2. A fresh DPoP key pair. NOTE: a real sign-in (`SiteMicropubSignIn`) mints its access
        //    token bound (via `cnf.jkt`) to the key pair generated *at that grant*, and the server
        //    verifies every subsequent proof against that exact binding — so
        //    `ANGLESITE_MICROPUB_E2E_TOKEN` must be a token minted without DPoP binding (or one
        //    whose binding this freshly-generated key pair happens to satisfy) for the calls below
        //    to authenticate. Arranging that is an operational concern of preparing the token out
        //    of band; it isn't something this test can do for itself without also driving the real
        //    sign-in UI, which is the exact interaction this suite is scoped to skip.
        let dpopKeyPair = DPoPKeyPair()
        let client = MicropubClient(
            endpoint: endpoints.micropub,
            accessToken: accessToken,
            dpopKeyPair: dpopKeyPair,
            transport: MicropubClient.defaultTransport
        )

        // 3. Import: a throwaway fixture site directory with one typed post, imported through the
        //    same `MicropubContentImport.importIfNeeded` → `client.create` path production uses.
        let siteDir = FileManager.default.temporaryDirectory.appending(path: "cms-e2e-site-\(UUID().uuidString)")
        let configDir = FileManager.default.temporaryDirectory.appending(path: "cms-e2e-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: siteDir.appending(path: "src/content/articles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fixtureSlug = "cms-e2e-import-\(Int(Date().timeIntervalSince1970))"
        try """
            ---
            title: Live E2E Import Fixture
            publishDate: 2026-01-01
            draft: true
            ---
            Imported by CMSModeLiveE2ETests.fullLoop().
            """.write(
                to: siteDir.appending(path: "src/content/articles/\(fixtureSlug).md"),
                atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: siteDir)
            try? FileManager.default.removeItem(at: configDir)
        }

        let firstImportCount = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)
        #expect(firstImportCount > 0, "expected the fixture post to import on the first run")

        let secondImportCount = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDir, configDirectory: configDir, client: client)
        #expect(secondImportCount == 0, "the second run should be a no-op — the fixture is already in the sync map")

        // 4. Create a new draft post directly (not via import) and read it back through `q=source`.
        let title = "CMS Live E2E \(UUID().uuidString.prefix(8))"
        let draft = MicropubPost.entry(title: title, content: "Created by CMSModeLiveE2ETests.fullLoop().", status: .draft)
        let createdURL = try await client.create(draft)
        let readBack = try await client.source(url: createdURL)
        #expect(readBack.firstString("name") == title)
        #expect(readBack.status == .draft)

        // 5. Publish, then poll (bounded retries, not a busy loop) until the live URL 200s — the
        //    spec's "published — site rebuilding" bake-lag handling.
        try await client.setStatus(url: createdURL, .published)
        let republished = try await client.source(url: createdURL)
        #expect(republished.status == .published)

        var isLive = false
        for _ in 0..<20 {
            var request = URLRequest(url: createdURL)
            request.httpMethod = "HEAD"
            if let (_, http) = try? await MicropubClient.defaultTransport(request),
                (200..<300).contains(http.statusCode)
            {
                isLive = true
                break
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        #expect(isLive, "published post at \(createdURL) never became live within the poll budget")
    }
}
