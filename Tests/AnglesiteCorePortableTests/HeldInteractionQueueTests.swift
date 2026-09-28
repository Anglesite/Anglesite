// Portable-target test (pure Foundation) so the Linux CI leg executes it — see
// DecisionProviderTests for the rationale.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("HeldInteractionQueue (#2066)")
struct HeldInteractionQueueTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static func decision(_ id: String, at offset: TimeInterval = 0, p: Double? = 0.8, confidence: Double? = 0.6) -> ScreeningDecision {
        ScreeningDecision(interactionID: id, verdict: .hold, rule: p == nil ? .noContent : .model,
                          probabilitySpam: p, confidence: confidence, decidedAt: now.addingTimeInterval(offset))
    }

    private static func interaction(_ id: String, host: String = "alice.example") throws -> ReceivedInteraction {
        try ReceivedInteraction(
            id: id, type: .webmention, source: URL(string: "https://\(host)/post")!,
            target: URL(string: "https://me.example/blog/hi")!, interactionType: .reply,
            author: .init(name: "Alice", url: nil, photo: nil), content: "hi",
            published: now, verified: now, verificationStatus: .verified)
    }

    @Test("joins holds with the inbox by id, keeping the ledger's order")
    func joinsByID() throws {
        let held = [Self.decision("b", at: 10), Self.decision("a", at: 20)]
        let queue = HeldInteractionQueue.build(held: held, interactions: [try Self.interaction("a"), try Self.interaction("b")])
        #expect(queue.map(\.id) == ["b", "a"])
        #expect(queue[0].interaction?.id == "b")
        #expect(queue[1].interaction?.author?.name == "Alice")
    }

    @Test("a hold whose interaction left the inbox is listed with a nil record, not dropped")
    func missingInteractionKept() throws {
        let queue = HeldInteractionQueue.build(held: [Self.decision("gone"), Self.decision("here")],
                                               interactions: [try Self.interaction("here")])
        #expect(queue.map(\.id) == ["gone", "here"])
        #expect(queue[0].interaction == nil)
        #expect(queue[1].interaction != nil)
    }

    @Test("duplicate inbox ids don't crash the join")
    func duplicateInboxIDs() throws {
        let queue = HeldInteractionQueue.build(
            held: [Self.decision("x")],
            interactions: [try Self.interaction("x", host: "first.example"), try Self.interaction("x", host: "second.example")])
        #expect(queue.count == 1)
        #expect(queue[0].interaction?.source.host() == "first.example")
    }

    @Test("display percentages round the model's numbers and are nil for deterministic rules")
    func percentages() {
        let model = HeldInteraction(decision: Self.decision("m", p: 0.876, confidence: 0.751), interaction: nil)
        #expect(model.spamPercent == 88)
        #expect(model.confidencePercent == 75)
        let rule = HeldInteraction(decision: Self.decision("r", p: nil, confidence: nil), interaction: nil)
        #expect(rule.spamPercent == nil && rule.confidencePercent == nil)
    }

    @Test("the ledger's held() feeds the queue and a ruling removes the item on the next build")
    func ledgerRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HeldInteractionQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        ledger.record([Self.decision("one", at: 0), Self.decision("two", at: 5)])
        #expect(HeldInteractionQueue.build(held: ledger.held(), interactions: []).map(\.id) == ["one", "two"])
        ledger.rule("one", approved: true)
        #expect(HeldInteractionQueue.build(held: ledger.held(), interactions: []).map(\.id) == ["two"])
    }
}
