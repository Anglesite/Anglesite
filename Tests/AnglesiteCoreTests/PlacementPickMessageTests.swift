import Testing
@testable import AnglesiteCore

@Suite struct PlacementPickMessageTests {
    @Test func decodesFullPayload() {
        let body: [String: Any] = [
            "type": "anglesite:pick-placement",
            "path": "/about/",
            "selector": [
                "tag": "SECTION", "id": "hero", "classes": ["hero", "hero--large"], "nthChild": 1,
                "ancestors": [
                    ["tag": "BODY", "classes": [] as [String], "nthChild": 1],
                    ["tag": "MAIN", "id": "content", "classes": [] as [String], "nthChild": 1],
                ],
                "role": "banner",
            ],
        ]
        guard case .success(let message) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected successful decode")
            return
        }
        #expect(message.path == "/about/")
        #expect(message.element.tag == "SECTION")
        #expect(message.element.id == "hero")
        #expect(message.element.classes == ["hero", "hero--large"])
        #expect(message.element.nthChild == 1)
        #expect(message.element.ancestors.count == 2)
        #expect(message.element.ancestors[0].tag == "BODY")
        #expect(message.element.ancestors[1].id == "content")
        #expect(message.element.role == "banner")
    }

    @Test func wrongTypeIsRejected() {
        let body: [String: Any] = ["type": "anglesite:apply-edit", "path": "/", "selector": [String: Any]()]
        guard case .failure(let error) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .wrongType)
    }

    @Test func missingSelectorIsMalformed() {
        let body: [String: Any] = ["type": "anglesite:pick-placement", "path": "/"]
        guard case .failure(let error) = PlacementPickMessage.decode(from: body) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .malformed)
    }
}
