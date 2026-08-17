import Testing
import Foundation
@testable import AnglesiteCore

/// #1440 part 1: the post-apply `npm install` (the next preview boot's hydrate step) is the
/// install verification — its resolution failure must surface as a clear, owner-phrased
/// finding instead of a generic dev-server timeout.
@Suite struct DependencyInstallFailureScannerTests {
    /// Real npm 11 ERESOLVE output shape, from the #1426 repro.
    private static let eresolveLines = [
        "npm error code ERESOLVE",
        "npm error ERESOLVE unable to resolve dependency tree",
        "npm error",
        "npm error While resolving: site@0.0.1",
        "npm error Found: astro@7.1.3",
        "npm error node_modules/astro",
        "npm error   astro@\"^7.1.3\" from the root project",
        "npm error",
        "npm error Could not resolve dependency:",
        "npm error peer astro@\"^6.3.0\" from @astrojs/cloudflare@13.5.0",
        "npm error node_modules/@astrojs/cloudflare",
        "npm error   @astrojs/cloudflare@\"13.5.0\" from the root project",
    ]

    @Test func detectsAnEresolveFailureInBootOutput() {
        let scanner = DependencyInstallFailureScanner()
        for line in Self.eresolveLines { scanner.ingest(line: line) }
        #expect(scanner.diagnosis != nil)
    }

    @Test func diagnosisNamesTheConflictingPackagesWhenNpmReportsThem() throws {
        let scanner = DependencyInstallFailureScanner()
        for line in Self.eresolveLines { scanner.ingest(line: line) }
        let diagnosis = try #require(scanner.diagnosis)
        #expect(diagnosis.contains("@astrojs/cloudflare"))
        #expect(diagnosis.contains("astro"))
    }

    @Test func diagnosisIsPhrasedAboutTheSiteNotAboutNpmMechanics() throws {
        let scanner = DependencyInstallFailureScanner()
        for line in Self.eresolveLines { scanner.ingest(line: line) }
        let diagnosis = try #require(scanner.diagnosis)
        // Consequence-first copy (CLAUDE.md advisory-UX rule): no npm/semver/exit-code jargon.
        #expect(!diagnosis.contains("ERESOLVE"))
        #expect(!diagnosis.contains("semver"))
        #expect(!diagnosis.contains("exit code"))
    }

    @Test func ordinaryBootOutputProducesNoDiagnosis() {
        let scanner = DependencyInstallFailureScanner()
        for line in [
            "==> npm ci (warm cache, offline-first)",
            "added 312 packages in 4s",
            "astro dev server running at http://127.0.0.1:4321",
        ] { scanner.ingest(line: line) }
        #expect(scanner.diagnosis == nil)
    }

    @Test func detectsAFailureEvenWithoutAParseablePeerLine() {
        let scanner = DependencyInstallFailureScanner()
        scanner.ingest(line: "npm error code ERESOLVE")
        scanner.ingest(line: "npm error ERESOLVE could not resolve")
        #expect(scanner.diagnosis != nil)
    }
}
