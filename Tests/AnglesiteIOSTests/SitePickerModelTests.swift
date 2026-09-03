import Testing
import Foundation
@testable import AnglesiteIOS
import AnglesiteCore
import AnglesiteSiteModel
import AnglesiteTestSupport

private struct FakeUbiquitousPackageDiscovery: UbiquitousPackageDiscovering {
    let urls: [URL]
    func discoverPackages() async -> [URL] { urls }
}

/// Runs `probe` at the moment `SitePickerModel.refresh()` reaches discovery — i.e. after it has
/// decided whether to publish `.loading` — so a test can assert what was on screen mid-flight.
private struct ProbingPackageDiscovery: UbiquitousPackageDiscovering {
    let urls: [URL]
    let probe: @Sendable @MainActor () -> Void
    func discoverPackages() async -> [URL] {
        await probe()
        return urls
    }
}

/// Holds the model under test so a `ProbingPackageDiscovery` built *before* the model can still
/// read its state (the discovery has to be passed to the model's initializer).
@MainActor
private final class StateProbe {
    weak var model: SitePickerModel?
    var observedStates: [SitePickerModel.State] = []

    func record() {
        if let state = model?.state { observedStates.append(state) }
    }
}

/// Parks the first `discoverPackages()` call until `release()`, so a test can start a slow
/// refresh, complete a faster one behind its back, and then let the slow one finish last.
private actor GatedPackageDiscovery: UbiquitousPackageDiscovering {
    private let firstCallURLs: [URL]
    private let laterCallURLs: [URL]
    private var callCount = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var waitingForPark: CheckedContinuation<Void, Never>?
    private var isParked = false
    private var isReleased = false

    init(firstCallURLs: [URL], laterCallURLs: [URL]) {
        self.firstCallURLs = firstCallURLs
        self.laterCallURLs = laterCallURLs
    }

    func discoverPackages() async -> [URL] {
        callCount += 1
        guard callCount == 1 else { return laterCallURLs }
        if !isReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked = continuation
                isParked = true
                waitingForPark?.resume()
                waitingForPark = nil
            }
        }
        return firstCallURLs
    }

    /// Event-driven rather than a sleep: resumes as soon as the first call is actually parked.
    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitingForPark = continuation
        }
    }

    func release() {
        isReleased = true
        parked?.resume()
        parked = nil
    }
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

    @Test("Refreshing an already-listed set of sites doesn't flicker back to loading")
    func refreshFromSitesSkipsLoading() async throws {
        let packageURL = try makePackage(displayName: "My Blog")
        let probe = StateProbe()
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: ProbingPackageDiscovery(urls: [packageURL]) { probe.record() })
        probe.model = model

        // First refresh: nothing on screen yet, so `.loading` is the right thing to show.
        await model.refresh()
        #expect(probe.observedStates == [.loading])
        guard case .sites(let sites) = model.state else {
            Issue.record("expected .sites after the first refresh, got \(model.state)")
            return
        }

        // Second refresh (the pull-to-refresh case): the list must stay up while it re-queries.
        await model.refresh()
        #expect(probe.observedStates.count == 2)
        #expect(probe.observedStates.last == .sites(sites))
        #expect(model.state == .sites(sites))
    }

    @Test("A slower earlier refresh can't overwrite a newer refresh's results")
    func staleRefreshDoesNotOverwriteNewerResult() async throws {
        let packageURL = try makePackage(displayName: "Made On The Mac")
        // The first (launch-time) query predates the new site and would report an empty container;
        // the second (pull-to-refresh) query sees it. The first one finishes last.
        let discovery = GatedPackageDiscovery(firstCallURLs: [], laterCallURLs: [packageURL])
        let model = SitePickerModel(
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: fakeContainer),
            packageDiscovery: discovery)

        let launchRefresh = Task { await model.refresh() }
        await discovery.waitUntilParked()

        await model.refresh()
        guard case .sites(let afterManualRefresh) = model.state else {
            Issue.record("expected .sites after the manual refresh, got \(model.state)")
            return
        }
        #expect(afterManualRefresh.map(\.displayName) == ["Made On The Mac"])

        await discovery.release()
        await launchRefresh.value
        // Without the generation guard this would have reverted to `.empty`.
        guard case .sites(let sites) = model.state else {
            Issue.record("expected the newer refresh's .sites to survive, got \(model.state)")
            return
        }
        #expect(sites.map(\.displayName) == ["Made On The Mac"])
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
