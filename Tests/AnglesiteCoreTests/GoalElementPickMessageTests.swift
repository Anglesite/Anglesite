import Testing
@testable import AnglesiteCore

@Suite struct GoalElementPickMessageTests {
    @Test func decodesAWellFormedBody() {
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element",
            "path": "/",
            "selector": ["tag": "SECTION", "nthChild": 2, "ancestors": []],
        ]
        switch GoalElementPickMessage.decode(from: body) {
        case .success(let message):
            #expect(message.path == "/")
            #expect(message.element.tag == "SECTION")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test func rejectsAnotherMessageTypeAsWrongType() {
        let body: [String: Any] = ["type": "anglesite:pick-placement", "path": "/", "selector": [:]]
        #expect(GoalElementPickMessage.decode(from: body) == .failure(.wrongType))
    }

    @Test func rejectsMissingSelectorAsMalformed() {
        let body: [String: Any] = ["type": "anglesite:pick-goal-element", "path": "/"]
        #expect(GoalElementPickMessage.decode(from: body) == .failure(.malformed))
    }
}
