import Foundation
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGPropDescriptor")
struct WYSIWYGPropDescriptorTests {
    @Test("round-trips through Codable for every kind")
    func codableRoundTrip() throws {
        let descriptors = [
            WYSIWYGPropDescriptor(name: "title", label: "Title", kind: .text),
            WYSIWYGPropDescriptor(name: "weight", label: "Weight", kind: .number),
            WYSIWYGPropDescriptor(name: "emphasis", label: "Emphasis", kind: .boolean),
            WYSIWYGPropDescriptor(name: "accentColor", label: "Accent Color", kind: .color),
            WYSIWYGPropDescriptor(name: "level", label: "Level", kind: .enumeration, enumOptions: ["1", "2", "3"]),
        ]
        for descriptor in descriptors {
            let data = try JSONEncoder().encode(descriptor)
            #expect(try JSONDecoder().decode(WYSIWYGPropDescriptor.self, from: data) == descriptor)
        }
    }

    @Test("enumOptions defaults to empty for non-enum kinds")
    func enumOptionsDefaultsEmpty() {
        let descriptor = WYSIWYGPropDescriptor(name: "title", label: "Title", kind: .text)
        #expect(descriptor.enumOptions.isEmpty)
    }
}
