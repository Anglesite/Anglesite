import Testing
import Foundation
import AnglesiteCore
import AnglesiteIOS
import AnglesiteTestSupport
@testable import AnglesiteIntents

/// Records how many gathers actually happened — the whole point of `SiteEntityUbiquityDiscovery`
/// is that this number stays at 1 across the several `EntityStringQuery` calls one Siri
/// interaction makes.
private actor CountingPackageDiscovery: UbiquitousPackageDiscovering {
    private let urls: [URL]
    private(set) var callCount = 0

    init(urls: [URL]) { self.urls = urls }

    func discoverPackages() async -> [URL] {
        callCount += 1
        return urls
    }
}

/// Parks its *first* gather until `release()`, so a test can hold a discovery open and pile
/// concurrent callers behind it. Mirrors `SitePickerModelTests`' `GatedPackageDiscovery`, but
/// later calls return immediately rather than parking too: a coalescing regression must show up
/// as a `callCount` assertion failure, never as a deadlocked test.
private actor GatedPackageDiscovery: UbiquitousPackageDiscovering {
    private let urls: [URL]
    private(set) var callCount = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var waitingForPark: CheckedContinuation<Void, Never>?
    private var isParked = false
    private var isReleased = false

    init(urls: [URL]) { self.urls = urls }

    func discoverPackages() async -> [URL] {
        callCount += 1
        guard callCount == 1, !isReleased else { return urls }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked = continuation
            isParked = true
            waitingForPark?.resume()
            waitingForPark = nil
        }
        return urls
    }

    /// Event-driven rather than a sleep: resumes as soon as the first gather is actually parked.
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

struct SiteEntityUbiquityDiscoveryTests {
    private let container = URL(fileURLWithPath: "/tmp/fake-ubiquity-container", isDirectory: true)
    private let siteA = URL(fileURLWithPath: "/tmp/fake-ubiquity-container/A.anglesite", isDirectory: true)
    private let siteB = URL(fileURLWithPath: "/tmp/fake-ubiquity-container/B.anglesite", isDirectory: true)

    private func makeSubject(
        containerResult: URL?,
        discovery: any UbiquitousPackageDiscovering,
        cacheTTL: Duration = .seconds(60)
    ) -> SiteEntityUbiquityDiscovery {
        SiteEntityUbiquityDiscovery(
            containerResolver: FakeUbiquityContainerResolver(result: containerResult),
            makePackageDiscovery: { discovery },
            ubiquityContainerIdentifier: "iCloud.io.dwk.anglesite.tests",
            cacheTTL: cacheTTL
        )
    }

    @Test("Discovered URLs pass through unchanged")
    func discoveredURLsPassThrough() async {
        let discovery = CountingPackageDiscovery(urls: [siteA, siteB])
        let subject = makeSubject(containerResult: container, discovery: discovery)
        #expect(await subject.discoveredURLs() == [siteA, siteB])
    }

    @Test("Repeated calls inside the TTL reuse one gather")
    func repeatedCallsInsideTTLReuseOneGather() async {
        let discovery = CountingPackageDiscovery(urls: [siteA])
        let subject = makeSubject(containerResult: container, discovery: discovery)

        let first = await subject.discoveredURLs()
        let second = await subject.discoveredURLs()
        let third = await subject.discoveredURLs()

        #expect(first == [siteA])
        #expect(second == first)
        #expect(third == first)
        let callCount = await discovery.callCount
        #expect(callCount == 1)
    }

    @Test("A call after the TTL expires re-discovers")
    func callAfterTTLExpiryRediscovers() async throws {
        let discovery = CountingPackageDiscovery(urls: [siteA])
        let subject = makeSubject(
            containerResult: container, discovery: discovery, cacheTTL: .milliseconds(10))

        _ = await subject.discoveredURLs()
        try await Task.sleep(for: .milliseconds(150))
        _ = await subject.discoveredURLs()

        let callCount = await discovery.callCount
        #expect(callCount == 2)
    }

    @Test("Concurrent callers share a single gather")
    func concurrentCallersShareOneGather() async {
        let discovery = GatedPackageDiscovery(urls: [siteA, siteB])
        let subject = makeSubject(containerResult: container, discovery: discovery)
        let callerCount = 6

        let results = await withTaskGroup(of: [URL].self, returning: [[URL]].self) { group in
            for _ in 0..<callerCount {
                group.addTask { await subject.discoveredURLs() }
            }
            // Only unblock the gather once at least one caller is definitely inside it, so the
            // remaining callers are racing a genuinely in-flight discovery rather than a
            // finished one.
            await discovery.waitUntilParked()
            await discovery.release()
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == callerCount)
        #expect(results.allSatisfy { $0 == [siteA, siteB] })
        let callCount = await discovery.callCount
        #expect(callCount == 1)
    }

    @Test("An unavailable container returns no URLs without gathering")
    func unavailableContainerSkipsGather() async {
        let discovery = CountingPackageDiscovery(urls: [siteA])
        let subject = makeSubject(containerResult: nil, discovery: discovery)

        let urls = await subject.discoveredURLs()

        #expect(urls.isEmpty)
        let callCount = await discovery.callCount
        #expect(callCount == 0)
    }
}
