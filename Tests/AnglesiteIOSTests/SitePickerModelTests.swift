import Testing
import Foundation
@testable import AnglesiteIOS
import AnglesiteCore
import AnglesiteSiteModel

private struct FakeUbiquityContainerResolver: UbiquityContainerResolving {
    let result: URL?
    func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { result }
}

private struct FakeUbiquitousPackageDiscovery: UbiquitousPackageDiscovering {
    let urls: [URL]
    func discoverPackages() async -> [URL] { urls }
}

/// A `final class` (not a `struct`) so `deinit` can clean up the scratch directory, mirroring
/// `AppSettingsTests`' scratch-`UserDefaults`-suite pattern.
@MainActor
final class SitePickerModelTests {
    private let scratchRoot: URL
    private let fakeContainer = URL(fileURLWithPath: "/tmp/fake-ubiquity-container", isDirectory: true)

    init() {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SitePickerModelTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test("Missing iCloud container surfaces iCloudUnavailable, not empty")
    func missingContainerSurfacesUnavailable() async {
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: nil),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: []))
        await model.refresh()
        #expect(model.state == .iCloudUnavailable)
    }

    @Test("Available container with no packages surfaces empty")
    func emptyContainerSurfacesEmpty() async {
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: []))
        await model.refresh()
        #expect(model.state == .empty)
    }

    @Test("Single discovered package surfaces one site")
    func singleSiteSurfacesInList() async throws {
        let packageURL = try makePackage(displayName: "My Blog")
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [packageURL]))
        await model.refresh()
        guard case .sites(let sites) = model.state else {
            Issue.record("expected .sites, got \(model.state)")
            return
        }
        #expect(sites.count == 1)
        #expect(sites.first?.displayName == "My Blog")
        #expect(sites.first?.packageURL == packageURL)
    }

    @Test("Multiple discovered packages surface sorted by display name")
    func multipleSitesSortedByName() async throws {
        let zebra = try makePackage(displayName: "Zebra Site")
        let apple = try makePackage(displayName: "Apple Site")
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [zebra, apple]))
        await model.refresh()
        guard case .sites(let sites) = model.state else {
            Issue.record("expected .sites, got \(model.state)")
            return
        }
        #expect(sites.map(\.displayName) == ["Apple Site", "Zebra Site"])
    }

    @Test("A package with no readable Info.plist marker is silently skipped")
    func unreadableMarkerSkipped() async throws {
        let corruptURL = scratchRoot.appendingPathComponent("Corrupt.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptURL, withIntermediateDirectories: true)
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: FakeUbiquitousPackageDiscovery(urls: [corruptURL]))
        await model.refresh()
        #expect(model.state == .empty)
    }
}
