import Testing
import Foundation
@testable import AnglesiteCore

/// #1440: a template-driven bump must not be auto-offered when it would violate the
/// `peerDependencies` range of a *foreign* dependency — one the site's own `package.json`
/// declares but the template doesn't track.
@Suite struct DependencyPeerCheckTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Range-floor satisfaction (the minimal, never-guess semver subset)

    @Test func caretRangeFloorInsideCaretPeerRangeSatisfies() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^6.4.8", peerRange: "^6.3.0") == true)
    }

    @Test func newerMajorFloorViolatesCaretPeerRange() {
        // The #1426/#1440 repro: template bumps astro to ^7.1.3, foreign
        // @astrojs/cloudflare@13.5.0 declares peer astro ^6.3.0.
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.1.3", peerRange: "^6.3.0") == false)
    }

    @Test func exactPeerVersionOnlyMatchesTheSameFloor() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^2.0.0", peerRange: "1.1.5") == false)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("1.1.5", peerRange: "1.1.5") == true)
    }

    @Test func tildePeerRangeBoundsTheMinorVersion() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("~1.2.9", peerRange: "~1.2.3") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^1.3.0", peerRange: "~1.2.3") == false)
    }

    @Test func gteAndLtComparatorsCombineAsAConjunction() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^6.4.0", peerRange: ">=6.3.0 <7.0.0") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.0.0", peerRange: ">=6.3.0 <7.0.0") == false)
    }

    @Test func orGroupsSatisfyWhenAnyAlternativeMatches() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.1.0", peerRange: "^6.0.0 || ^7.0.0") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^8.0.0", peerRange: "^6.0.0 || ^7.0.0") == false)
    }

    @Test func wildcardPeerRangeAlwaysSatisfies() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.1.3", peerRange: "*") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.1.3", peerRange: "6.x") == false)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^6.9.0", peerRange: "6.x") == true)
    }

    @Test func partialBareVersionsActAsMajorOrMinorWildcards() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^6.4.0", peerRange: "6") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.0.0", peerRange: "6") == false)
    }

    @Test func caretZeroMajorPeerRangeStaysWithinTheMinor() {
        // npm semantics: ^0.2.3 means >=0.2.3 <0.3.0.
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^0.2.5", peerRange: "^0.2.3") == true)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^0.3.0", peerRange: "^0.2.3") == false)
    }

    @Test func unparseablePeerRangeIsNilNeverAGuess() {
        #expect(DependencyPeerCheck.offeredRangeSatisfies("^7.1.3", peerRange: "workspace:*") == nil)
        #expect(DependencyPeerCheck.offeredRangeSatisfies("latest", peerRange: "^6.3.0") == nil)
    }

    // MARK: - Partition

    private static let astroBump = DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^7.1.3")

    @Test func partitionHoldsABumpAForeignPeerRangeExcludes() {
        let result = DependencyPeerCheck.partition(
            updates: [Self.astroBump],
            foreignPeerRequirements: ["@astrojs/cloudflare": ["astro": "^6.3.0"]]
        )
        #expect(result.allowed.isEmpty)
        #expect(result.held == [
            DependencyHeldUpdate(
                offer: Self.astroBump,
                blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")]
            )
        ])
    }

    @Test func partitionAllowsABumpWithinEveryForeignPeerRange() {
        let bump = DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^6.4.8")
        let result = DependencyPeerCheck.partition(
            updates: [bump],
            foreignPeerRequirements: ["@astrojs/cloudflare": ["astro": "^6.3.0"]]
        )
        #expect(result.allowed == [bump])
        #expect(result.held.isEmpty)
    }

    @Test func partitionIgnoresPeerRangesForPackagesNotBeingBumped() {
        let result = DependencyPeerCheck.partition(
            updates: [Self.astroBump],
            foreignPeerRequirements: ["some-plugin": ["react": "^17.0.0"]]
        )
        #expect(result.allowed == [Self.astroBump])
        #expect(result.held.isEmpty)
    }

    @Test func partitionNeverGuessesOnAnUnparseablePeerRange() {
        // An unreadable peer range must not hold the offer back — the post-apply
        // install (and its surfaced failure) is the backstop for what we can't parse.
        let result = DependencyPeerCheck.partition(
            updates: [Self.astroBump],
            foreignPeerRequirements: ["@astrojs/cloudflare": ["astro": "workspace:*"]]
        )
        #expect(result.allowed == [Self.astroBump])
        #expect(result.held.isEmpty)
    }

    @Test func partitionCollectsEveryBlockerForOneHeldBump() {
        let result = DependencyPeerCheck.partition(
            updates: [Self.astroBump],
            foreignPeerRequirements: [
                "@astrojs/cloudflare": ["astro": "^6.3.0"],
                "astro-seo-schema": ["astro": ">=5.0.0 <7.0.0"],
            ]
        )
        #expect(result.held.count == 1)
        #expect(result.held.first?.blockers == [
            DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0"),
            DependencyPeerBlocker(dependentName: "astro-seo-schema", requiredRange: ">=5.0.0 <7.0.0"),
        ])
    }

    // MARK: - Reading foreign peer requirements from the site

    @Test func readsPeerRequirementsFromTheLockfile() throws {
        let source = tmpDir()
        let lockfile = """
        {
          "name": "site", "lockfileVersion": 3,
          "packages": {
            "": { "dependencies": { "astro": "^6.2.0", "@astrojs/cloudflare": "13.5.0" } },
            "node_modules/@astrojs/cloudflare": {
              "version": "13.5.0",
              "peerDependencies": { "astro": "^6.3.0" }
            },
            "node_modules/astro": { "version": "6.4.0" }
          }
        }
        """
        try lockfile.write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        let peers = DependencyPeerCheck.foreignPeerRequirements(
            sourceDirectory: source, untrackedDependencyNames: ["@astrojs/cloudflare"])
        #expect(peers == ["@astrojs/cloudflare": ["astro": "^6.3.0"]])
    }

    @Test func fallsBackToNodeModulesPackageJSONWhenTheLockfileHasNoEntry() throws {
        let source = tmpDir()
        let pkgDir = source.appendingPathComponent("node_modules/@astrojs/cloudflare")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        let pkg = """
        { "name": "@astrojs/cloudflare", "version": "13.5.0", "peerDependencies": { "astro": "^6.3.0" } }
        """
        try pkg.write(to: pkgDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let peers = DependencyPeerCheck.foreignPeerRequirements(
            sourceDirectory: source, untrackedDependencyNames: ["@astrojs/cloudflare"])
        #expect(peers == ["@astrojs/cloudflare": ["astro": "^6.3.0"]])
    }

    @Test func onlyReadsTheNamedUntrackedDependencies() throws {
        let source = tmpDir()
        let lockfile = """
        {
          "lockfileVersion": 3,
          "packages": {
            "node_modules/@astrojs/cloudflare": { "peerDependencies": { "astro": "^6.3.0" } },
            "node_modules/astro-seo-schema": { "peerDependencies": { "astro": "^6.0.0" } }
          }
        }
        """
        try lockfile.write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        let peers = DependencyPeerCheck.foreignPeerRequirements(
            sourceDirectory: source, untrackedDependencyNames: ["@astrojs/cloudflare"])
        #expect(peers["astro-seo-schema"] == nil)
    }

    @Test func returnsEmptyWhenNeitherLockfileNorNodeModulesExists() {
        let peers = DependencyPeerCheck.foreignPeerRequirements(
            sourceDirectory: tmpDir(), untrackedDependencyNames: ["@astrojs/cloudflare"])
        #expect(peers.isEmpty)
    }
}
