import Testing
import Foundation
@testable import AnglesiteIOS
import AnglesiteTestSupport

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite,
/// mirroring `SiteSelectionModelTests`.
@MainActor
final class NavigationRestorationModelTests {
    private let scratch = TemporaryUserDefaults(label: "navigation-restoration")
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    private static let siteID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let otherSiteID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test("recordPosition then restorePosition round-trips for the same site")
    func recordAndRestoreRoundTrips() {
        let model = NavigationRestorationModel(defaults: defaults)

        model.recordPosition(siteID: Self.siteID, typeID: "note", selection: .new(typeID: "note"))

        let restored = model.restorePosition(forSite: Self.siteID)
        #expect(restored?.typeID == "note")
        #expect(restored?.selection == .new(typeID: "note"))
    }

    @Test("restorePosition round-trips an existing-post selection across instances")
    func existingSelectionRoundTripsAcrossInstances() {
        let url = URL(string: "https://example.com/notes/hello")!
        let writer = NavigationRestorationModel(defaults: defaults)
        writer.recordPosition(siteID: Self.siteID, typeID: nil, selection: .existing(postURL: url))

        let reader = NavigationRestorationModel(defaults: defaults)
        let restored = reader.restorePosition(forSite: Self.siteID)
        #expect(restored?.typeID == nil)
        #expect(restored?.selection == .existing(postURL: url))
    }

    @Test("restorePosition returns nil for a site that never recorded a position")
    func noRecordReturnsNil() {
        let model = NavigationRestorationModel(defaults: defaults)
        #expect(model.restorePosition(forSite: Self.siteID) == nil)
    }

    @Test("restorePosition returns nil when the persisted bundle belongs to a different site")
    func siteMismatchReturnsNil() {
        let model = NavigationRestorationModel(defaults: defaults)
        model.recordPosition(siteID: Self.otherSiteID, typeID: "note", selection: nil)

        #expect(model.restorePosition(forSite: Self.siteID) == nil)
    }

    @Test("recordPosition with a nil selection persists and restores nil")
    func nilSelectionRoundTrips() {
        let model = NavigationRestorationModel(defaults: defaults)
        model.recordPosition(siteID: Self.siteID, typeID: nil, selection: nil)

        let restored = model.restorePosition(forSite: Self.siteID)
        #expect(restored?.typeID == nil)
        #expect(restored?.selection == nil)
    }

    @Test("markSessionWarm adds the site to warmSessionIDs and persists across instances")
    func markSessionWarmPersists() {
        let writer = NavigationRestorationModel(defaults: defaults)
        writer.markSessionWarm(siteID: Self.siteID)
        #expect(writer.warmSessionIDs == [Self.siteID])

        let reader = NavigationRestorationModel(defaults: defaults)
        #expect(reader.warmSessionIDs == [Self.siteID])
    }

    @Test("markSessionEnded removes the site from warmSessionIDs and persists across instances")
    func markSessionEndedPersists() {
        let model = NavigationRestorationModel(defaults: defaults)
        model.markSessionWarm(siteID: Self.siteID)
        model.markSessionWarm(siteID: Self.otherSiteID)

        model.markSessionEnded(siteID: Self.siteID)
        #expect(model.warmSessionIDs == [Self.otherSiteID])

        let reader = NavigationRestorationModel(defaults: defaults)
        #expect(reader.warmSessionIDs == [Self.otherSiteID])
    }

    @Test("markSessionEnded for a site that was never warm is a no-op")
    func markSessionEndedNoOp() {
        let model = NavigationRestorationModel(defaults: defaults)
        model.markSessionEnded(siteID: Self.siteID)
        #expect(model.warmSessionIDs.isEmpty)
    }
}
