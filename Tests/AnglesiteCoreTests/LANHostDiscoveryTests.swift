import Testing
@testable import AnglesiteCore

private func lanHost(_ name: String) -> DiscoveredLANHost {
    DiscoveredLANHost(siteName: name, dnsName: "\(name).local", ipAddress: "192.168.1.1",
                       previewPort: 4321, mcpPort: 4399)
}

@Suite("selectLANHost")
struct SelectLANHostTests {
    @Test("zero hosts selects empty")
    func zeroHostsIsEmpty() {
        #expect(selectLANHost(from: []) == .empty)
    }

    @Test("exactly one host auto-populates")
    func oneHostAutoPopulates() {
        let host = lanHost("blog")
        #expect(selectLANHost(from: [host]) == .autoPopulate(host))
    }

    @Test("multiple hosts requires a choice, in discovery order")
    func multipleHostsChooseFrom() {
        let hosts = [lanHost("blog"), lanHost("docs")]
        #expect(selectLANHost(from: hosts) == .chooseFrom(hosts))
    }
}

@Suite("DiscoveredLANHost TXT record parsing")
struct DiscoveredLANHostTXTTests {
    @Test("decodes a well-formed TXT record")
    func decodesWellFormed() {
        let host = DiscoveredLANHost(
            txtRecord: ["site": "my-blog", "previewPort": "4321", "mcpPort": "4399"],
            dnsName: "mac-studio.local", ipAddress: "192.168.1.42")
        #expect(host == DiscoveredLANHost(
            siteName: "my-blog", dnsName: "mac-studio.local", ipAddress: "192.168.1.42",
            previewPort: 4321, mcpPort: 4399))
    }

    @Test("returns nil when site is missing")
    func nilWhenSiteMissing() {
        #expect(DiscoveredLANHost(txtRecord: ["previewPort": "4321", "mcpPort": "4399"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }

    @Test("returns nil when previewPort fails to parse as Int")
    func nilWhenPreviewPortNotInt() {
        #expect(DiscoveredLANHost(txtRecord: ["site": "my-blog", "previewPort": "not-a-number", "mcpPort": "4399"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }

    @Test("returns nil when mcpPort is missing")
    func nilWhenMcpPortMissing() {
        #expect(DiscoveredLANHost(txtRecord: ["site": "my-blog", "previewPort": "4321"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }
}
