import Testing
import Foundation
@testable import AnglesiteCore

struct ShareExtensionSiteAccessTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-share-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("listSites returns an empty array when the directory is nil")
    func listSitesNilDirectory() {
        #expect(ShareExtensionSiteAccess.listSites(directory: nil).isEmpty)
    }

    @Test("listSites reflects a published manifest")
    func listSitesReadsManifest() throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        let sites = ShareExtensionSiteAccess.listSites(directory: dir)
        #expect(sites.map(\.id) == ["a"])
    }

    @Test("withScopedAccess throws unavailable when the directory is nil")
    func withScopedAccessNilDirectory() async {
        await #expect(throws: ShareExtensionSiteAccess.AccessError.unavailable) {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "a", directory: nil) { _ in }
        }
    }

    @Test("withScopedAccess throws siteNotFound for an unknown id")
    func withScopedAccessUnknownSite() async throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        await #expect(throws: ShareExtensionSiteAccess.AccessError.siteNotFound) {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "does-not-exist", directory: dir) { _ in }
        }
    }

    @Test("withScopedAccess throws noGrant for unresolvable bookmark data")
    func withScopedAccessBadBookmark() async throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish(
            [SharedSite(id: "a", name: "Alpha", bookmarkData: Data([0xFF, 0x00]), lastSeen: Date())], to: dir)
        do {
            _ = try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: "a", directory: dir) { _ in }
            Issue.record("expected noGrant to be thrown")
        } catch ShareExtensionSiteAccess.AccessError.noGrant {
            // expected
        }
    }
}
