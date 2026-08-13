import Testing
@testable import AnglesiteCore

@Suite
struct CMSModeStatusTests {
    @Test("provisioned when activeWorkerIDs includes micropub")
    func provisionedWithMicropub() {
        var settings = SiteSettings()
        settings.activeWorkerIDs = ["indieauth", "micropub", "webmention"]
        #expect(CMSModeStatus.isProvisioned(settings: settings) == true)
    }

    @Test("not provisioned when micropub isn't active")
    func notProvisionedWithoutMicropub() {
        var settings = SiteSettings()
        settings.activeWorkerIDs = ["webmention"]
        #expect(CMSModeStatus.isProvisioned(settings: settings) == false)
    }

    @Test("not provisioned with no active workers at all")
    func notProvisionedEmpty() {
        #expect(CMSModeStatus.isProvisioned(settings: SiteSettings()) == false)
    }
}
