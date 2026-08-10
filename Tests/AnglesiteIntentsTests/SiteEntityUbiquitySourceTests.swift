import Testing
import Foundation
@testable import AnglesiteIntents
import AnglesiteSiteModel

/// A `final class` (not `struct`) so `deinit` can clean up the scratch directory — mirrors
/// `SitePickerModelTests`' pattern (`Tests/AnglesiteIOSTests/SitePickerModelTests.swift`).
final class SiteEntityUbiquitySourceTests {
    private let scratchRoot: URL

    init() {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteEntityUbiquitySourceTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        let root = scratchRoot
        try? FileManager.default.removeItem(at: root)
    }

    private func makePackage(displayName: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent("\(displayName).anglesite", isDirectory: true)
        _ = try AnglesitePackage.createSkeleton(at: url, displayName: displayName)
        return url
    }

    @Test("A well-formed package maps to a SiteEntity with matching id and name")
    func wellFormedPackageMapsToEntity() throws {
        let url = try makePackage(displayName: "My Blog")
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [url])
        #expect(entities.count == 1)
        #expect(entities.first?.name == "My Blog")
        #expect(entities.first?.directory == url)
    }

    @Test("A package with no marker (malformed) is dropped, not thrown")
    func malformedPackageIsDropped() throws {
        let url = scratchRoot.appendingPathComponent("Not A Package.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [url])
        #expect(entities.isEmpty)
    }

    @Test("Multiple packages all map, one bad package among good ones is skipped")
    func mixedGoodAndBadPackages() throws {
        let good = try makePackage(displayName: "Good Site")
        let bad = scratchRoot.appendingPathComponent("Bad.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let entities = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [good, bad])
        #expect(entities.count == 1)
        #expect(entities.first?.name == "Good Site")
    }

    @Test("entities(for:) returns only ids that match")
    func entitiesForIdentifiersFilters() throws {
        let a = try makePackage(displayName: "Site A")
        let b = try makePackage(displayName: "Site B")
        let all = SiteEntityUbiquitySource.siteEntities(fromPackageURLs: [a, b])
        let targetID = all.first { $0.name == "Site A" }!.id
        let filtered = SiteEntityUbiquitySource.entities(for: [targetID], in: [a, b])
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "Site A")
    }

    @Test("entities(matching:) is a case-insensitive substring match")
    func entitiesMatchingIsCaseInsensitiveSubstring() throws {
        let url = try makePackage(displayName: "My Portfolio Site")
        let matches = SiteEntityUbiquitySource.entities(matching: "portfolio", in: [url])
        #expect(matches.count == 1)
        let noMatches = SiteEntityUbiquitySource.entities(matching: "nonexistent", in: [url])
        #expect(noMatches.isEmpty)
    }

    @Test("defaultResult() returns the single site when exactly one exists")
    func defaultResultReturnsSingleSite() throws {
        let url = try makePackage(displayName: "Only Site")
        #expect(SiteEntityUbiquitySource.defaultResult(in: [url])?.name == "Only Site")
    }

    @Test("defaultResult() returns nil when zero or multiple sites exist")
    func defaultResultReturnsNilWhenNotExactlyOne() throws {
        #expect(SiteEntityUbiquitySource.defaultResult(in: []) == nil)
        let a = try makePackage(displayName: "Site A")
        let b = try makePackage(displayName: "Site B")
        #expect(SiteEntityUbiquitySource.defaultResult(in: [a, b]) == nil)
    }
}
