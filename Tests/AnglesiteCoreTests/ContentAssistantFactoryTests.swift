import Testing
@testable import AnglesiteCore

@Suite struct ContentAssistantFactoryTests {
    @Test func makeReturnsBackendMatchingToolchain() {
        let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute)
        #if compiler(>=6.4) && canImport(FoundationModels)
        #expect(assistant != nil)
        // Served on-device until the PCC entitlement lands, and advertised as such (#1965).
        #expect(assistant?.capabilities.providerName == "On-Device")
        #else
        #expect(assistant == nil)
        #endif
    }
}
