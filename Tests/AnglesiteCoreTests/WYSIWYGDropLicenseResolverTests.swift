import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WYSIWYGDropLicenseResolver (#1671)")
struct WYSIWYGDropLicenseResolverTests {
    private let enabledSelection = FileLicenseSelection(isEnabled: true, catalogID: "cc-by-4.0")

    @Test("a collection that suppresses file embedding resolves to nil, even with an enabled selection")
    func suppressedCollectionResolvesNil() {
        let license = WYSIWYGDropLicenseResolver.resolve(
            policy: LicensingPolicy(), route: "/bookmarks/some-post/", lastUsed: enabledSelection)
        #expect(license == nil)
    }

    @Test("no persisted selection resolves to nil rather than falling back to the resolved default")
    func noPersistedSelectionResolvesNil() {
        var policy = LicensingPolicy()
        policy.defaultLicense = LicenseRef(url: "https://creativecommons.org/publicdomain/zero/1.0/", name: "CC0 1.0")
        let license = WYSIWYGDropLicenseResolver.resolve(policy: policy, route: "/notes/some-post/", lastUsed: nil)
        #expect(license == nil)
    }

    @Test("a persisted-but-disabled selection resolves to nil")
    func disabledSelectionResolvesNil() {
        let disabled = FileLicenseSelection(isEnabled: false, catalogID: "cc-by-4.0")
        let license = WYSIWYGDropLicenseResolver.resolve(policy: LicensingPolicy(), route: "/notes/some-post/", lastUsed: disabled)
        #expect(license == nil)
    }

    @Test("an enabled selection resolves to the matching catalog entry's LicenseRef")
    func enabledSelectionResolvesCatalogEntry() {
        let license = WYSIWYGDropLicenseResolver.resolve(
            policy: LicensingPolicy(), route: "/notes/some-post/", lastUsed: enabledSelection)
        #expect(license == LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }?.ref)
    }

    @Test("an unknown catalogID resolves to nil rather than throwing")
    func unknownCatalogIDResolvesNil() {
        let unknown = FileLicenseSelection(isEnabled: true, catalogID: "not-a-real-license")
        let license = WYSIWYGDropLicenseResolver.resolve(policy: LicensingPolicy(), route: "/notes/some-post/", lastUsed: unknown)
        #expect(license == nil)
    }

    @Test("an explicit per-collection license override on an otherwise-suppressed collection still resolves")
    func explicitOverrideOnNonAssertingCollectionResolves() {
        var policy = LicensingPolicy()
        let override = LicenseRef(url: "https://creativecommons.org/licenses/by-sa/4.0/", name: "CC BY-SA 4.0")
        policy.setRule(.license(override), for: .bookmarks)
        let license = WYSIWYGDropLicenseResolver.resolve(policy: policy, route: "/bookmarks/some-post/", lastUsed: enabledSelection)
        #expect(license == LicenseCatalog.entries.first { $0.id == "cc-by-4.0" }?.ref)
    }
}
