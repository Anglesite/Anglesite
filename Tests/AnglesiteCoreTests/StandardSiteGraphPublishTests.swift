import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Standard.site graph records")
struct StandardSiteGraphRecordsTests {
    @Test("subscription record carries the lexicon's $type and fields")
    func recordShape() throws {
        let record = StandardSiteGraphSubscriptionRecord(
            publication: "at://did:plc:friend/site.standard.publication/anglesite-abc",
            createdAt: "2026-08-15T00:00:00Z"
        )
        let data = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["$type"] as? String == "site.standard.graph.subscription")
        #expect(object["publication"] as? String == "at://did:plc:friend/site.standard.publication/anglesite-abc")
        #expect(object["createdAt"] as? String == "2026-08-15T00:00:00Z")
    }
}
