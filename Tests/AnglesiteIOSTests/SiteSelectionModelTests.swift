import Testing
import Foundation
@testable import AnglesiteIOS

/// A `final class` (not a `struct`) so `deinit` can drop the throwaway `UserDefaults` suite,
/// mirroring `AppSettingsTests`' scratch-suite pattern (`Tests/AnglesiteCoreTests/AppSettingsTests.swift`).
@MainActor
final class SiteSelectionModelTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let suite = "test-site-selection-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSite(name: String, id: UUID = UUID()) -> SitePickerModel.DiscoveredSite {
        SitePickerModel.DiscoveredSite(
            id: id, displayName: name, packageURL: URL(fileURLWithPath: "/tmp/\(name).anglesite"))
    }

    @Test("select persists the site and updates selectedSite")
    func selectPersists() {
        let model = SiteSelectionModel(defaults: defaults)
        let site = makeSite(name: "My Blog")

        model.select(site)

        #expect(model.selectedSite == site)
        #expect(defaults.string(forKey: "siteSelection.selectedSiteID") == site.id.uuidString)
    }

    @Test("select(nil) clears the persisted site")
    func selectNilClears() {
        let model = SiteSelectionModel(defaults: defaults)
        model.select(makeSite(name: "My Blog"))

        model.select(nil)

        #expect(model.selectedSite == nil)
        #expect(defaults.string(forKey: "siteSelection.selectedSiteID") == nil)
    }

    @Test("restoreSelection selects the persisted site when present in the list")
    func restoreSelectsPersistedSite() {
        let site = makeSite(name: "My Blog")
        let other = makeSite(name: "Other Site")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(site)

        let restored = SiteSelectionModel(defaults: defaults)
        restored.restoreSelection(from: [other, site])

        #expect(restored.selectedSite == site)
    }

    @Test("restoreSelection leaves selectedSite nil when the persisted site isn't in the list")
    func restoreLeavesNilWhenMissing() {
        let site = makeSite(name: "My Blog")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(site)

        let restored = SiteSelectionModel(defaults: defaults)
        restored.restoreSelection(from: [makeSite(name: "Different Site")])

        #expect(restored.selectedSite == nil)
    }

    @Test("restoreSelection leaves selectedSite nil when nothing was persisted")
    func restoreLeavesNilWhenNothingPersisted() {
        let model = SiteSelectionModel(defaults: defaults)

        model.restoreSelection(from: [makeSite(name: "My Blog")])

        #expect(model.selectedSite == nil)
    }

    @Test("restoreSelection never overwrites an already-active selection")
    func restoreDoesNotOverwriteActiveSelection() {
        let active = makeSite(name: "Active Site")
        let persisted = makeSite(name: "Persisted Site")
        let writer = SiteSelectionModel(defaults: defaults)
        writer.select(persisted)

        let model = SiteSelectionModel(defaults: defaults)
        model.select(active)
        model.restoreSelection(from: [persisted, active])

        #expect(model.selectedSite == active)
    }
}
