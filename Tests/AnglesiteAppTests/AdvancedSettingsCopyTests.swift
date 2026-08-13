import Testing
@testable import AnglesiteAppCore

@Suite("AdvancedSettingsCopy")
struct AdvancedSettingsCopyTests {
    @Test("section title reads Remote Development Server")
    func sectionTitle() {
        #expect(AdvancedSettingsCopy.sectionTitle == "Remote Development Server")
    }

    @Test("host placeholder reads my-mac.local")
    func hostPlaceholder() {
        #expect(AdvancedSettingsCopy.hostPlaceholder == "my-mac.local")
    }

    @Test("port placeholder has no locale grouping", arguments: [4321, 4399, 80, 65535])
    func portPlaceholderNoGrouping(port: Int) {
        #expect(AdvancedSettingsCopy.portPlaceholder(port) == String(port))
        #expect(!AdvancedSettingsCopy.portPlaceholder(port).contains(","))
    }
}
