// Portable-target test (pure Foundation, temp-dir file I/O only) so the Linux CI leg executes
// it — see DecisionProviderTests for the rationale. The git-committing half of the gate is
// covered by ReceivedInteractionSyncTests (macOS, real `git`).
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("InteractionScreener")
struct InteractionScreeningTests {

    /// Answers the spam question with a fixed `p(spam)` per interaction source host, or throws.
    private struct CannedProvider: DecisionProvider {
        var spamProbabilityByHost: [String: Double] = [:]
        var error: DecisionError? = nil
        func decide(state: String, questions: [DecisionQuestion]) async throws -> [DecisionAnswer] {
            if let error { throw error }
            #expect(questions == [InteractionScreener.spamQuestion])
            let host = spamProbabilityByHost.keys.first { state.contains($0) }
            let p = host.flatMap { spamProbabilityByHost[$0] } ?? 0
            return [DecisionAnswer(probabilities: [p, 1 - p])]
        }
    }

    private actor LogSink {
        var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    private static func interaction(
        id: String, host: String, kind: ReceivedInteraction.InteractionType = .reply,
        content: String? = "Nice post", vouch: ReceivedInteraction.Vouch? = nil
    ) throws -> ReceivedInteraction {
        try ReceivedInteraction(
            id: id, type: .webmention, source: URL(string: "https://\(host)/post")!,
            target: URL(string: "https://me.example/blog/hi")!, interactionType: kind,
            author: .init(name: "Someone", url: URL(string: "https://\(host)/"), photo: nil),
            content: content, published: fixedNow, verified: fixedNow, verificationStatus: .verified,
            vouch: vouch)
    }

    private static func tempConfigDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionScreeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - verdict thresholds (pure)

    @Test("verdict: hold at or above the hold threshold, publish when confident and below it")
    func verdictThresholds() {
        let policy = InteractionScreeningPolicy.default
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.9, 0.1]), policy: policy) == .hold)
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.5, 0.5]), policy: policy) == .hold)
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.1, 0.9]), policy: policy) == .publish)
    }

    @Test("verdict: an uncertain answer below minimum confidence is held even when p(spam) is low")
    func verdictHoldsLowConfidence() {
        // p = 0.4 → confidence 0.2 < 0.3 → hold; p = 0.3 → confidence 0.4 → publish.
        let policy = InteractionScreeningPolicy.default
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.4, 0.6]), policy: policy) == .hold)
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.3, 0.7]), policy: policy) == .publish)
    }

    @Test("verdict: drop only when enabled, above its threshold, and confident")
    func verdictDropRequiresOptIn() {
        var policy = InteractionScreeningPolicy.default
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.99, 0.01]), policy: policy) == .hold)
        policy.dropThreshold = 0.95
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.99, 0.01]), policy: policy) == .drop)
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.9, 0.1]), policy: policy) == .hold)
        policy.minimumConfidence = 0.999
        #expect(InteractionScreener.verdict(for: .init(probabilities: [0.99, 0.01]), policy: policy) == .hold)
    }

    // MARK: - state rendering

    @Test("state carries the labelled record and truncates content to the policy limit")
    func stateRendering() throws {
        let long = String(repeating: "x", count: 50)
        let interaction = try Self.interaction(
            id: "wm-1", host: "alice.example", content: long,
            vouch: .init(url: URL(string: "https://vouch.example/")!, verified: false))
        var policy = InteractionScreeningPolicy.default
        policy.maxContentCharacters = 10
        let state = InteractionScreener.state(for: interaction, policy: policy)
        #expect(state.contains("Protocol: webmention"))
        #expect(state.contains("Kind: reply"))
        #expect(state.contains("Author: Someone — https://alice.example/"))
        #expect(state.contains("Vouch: https://vouch.example/ (not verified)"))
        #expect(state.hasSuffix("Content:\n" + String(repeating: "x", count: 10)))
    }

    @Test("state omits the content block for blank content")
    func stateOmitsBlankContent() throws {
        let state = InteractionScreener.state(for: try Self.interaction(id: "wm-1", host: "a.example", content: "  \n"))
        #expect(!state.contains("Content:"))
    }

    // MARK: - screen: rule order

    @Test("deterministic rules win before the model is consulted")
    func deterministicRulesFirst() async throws {
        let sink = LogSink()
        let screener = InteractionScreener(
            provider: CannedProvider(error: .unavailable("must not be called")),
            now: { Self.fixedNow }, log: { await sink.append($0) })
        let vouched = try Self.interaction(
            id: "wm-vouch", host: "spam.example",
            vouch: .init(url: URL(string: "https://trusted.example/")!, verified: true))
        let like = try Self.interaction(id: "wm-like", host: "spam.example", kind: .like, content: nil)
        let grandfathered = try Self.interaction(id: "wm-old", host: "spam.example")
        let ruledOut = try Self.interaction(id: "wm-ruled", host: "fine.example")

        let outcome = await screener.screen(
            [vouched, like, grandfathered, ruledOut],
            isAlreadyPublished: { $0 == "wm-old" },
            ownerRuling: { $0 == "wm-ruled" ? OwnerRuling(approved: false, ruledAt: Self.fixedNow) : nil })

        #expect(outcome.decisions.map(\.rule) == [.verifiedVouch, .noContent, .alreadyPublished, .ownerRuling])
        #expect(outcome.published.map(\.id) == ["wm-vouch", "wm-like", "wm-old"])
        #expect(outcome.held.map(\.id) == ["wm-ruled"])
        #expect(outcome.dropped.isEmpty)
        #expect(await sink.lines.isEmpty)
    }

    @Test("the model decides the rest and its output is kept for the ledger")
    func modelDecidesRemainder() async throws {
        let provider = CannedProvider(spamProbabilityByHost: ["spam.example": 0.9, "fine.example": 0.05])
        let screener = InteractionScreener(provider: provider, now: { Self.fixedNow }, log: { _ in })
        let outcome = await screener.screen(
            [try Self.interaction(id: "wm-s", host: "spam.example"), try Self.interaction(id: "wm-f", host: "fine.example")],
            isAlreadyPublished: { _ in false }, ownerRuling: { _ in nil })

        #expect(outcome.held.map(\.id) == ["wm-s"])
        #expect(outcome.published.map(\.id) == ["wm-f"])
        let spam = try #require(outcome.decisions.first)
        #expect(spam.rule == .model && spam.verdict == .hold)
        #expect(spam.probabilitySpam == 0.9)
        #expect(spam.confidence.map { abs($0 - 0.8) < 1e-12 } == true)
        // Scores are log-probabilities: re-softmaxing them at T=1 gives the distribution back.
        let scores = try #require(spam.scores)
        let roundTrip = DecisionScoring.softmax(scores, temperature: 1)
        #expect(abs(roundTrip[0] - 0.9) < 1e-9)
        #expect(spam.decidedAt == Self.fixedNow)
    }

    @Test("an unavailable model fails open, publishes, and logs once per batch")
    func unavailableModelFailsOpen() async throws {
        let sink = LogSink()
        let screener = InteractionScreener(
            provider: CannedProvider(error: .unavailable("asset missing")),
            now: { Self.fixedNow }, log: { await sink.append($0) })
        let outcome = await screener.screen(
            [try Self.interaction(id: "wm-1", host: "a.example"), try Self.interaction(id: "wm-2", host: "b.example")],
            isAlreadyPublished: { _ in false }, ownerRuling: { _ in nil })

        #expect(outcome.published.count == 2 && outcome.held.isEmpty)
        #expect(outcome.decisions.allSatisfy { $0.rule == .modelUnavailable && $0.verdict == .publish })
        let lines = await sink.lines
        #expect(lines.count == 1)
        #expect(lines[0].contains("asset missing"))
    }

    @Test("an owner Accept publishes an interaction the model would hold")
    func ownerApprovalOverridesModel() async throws {
        let screener = InteractionScreener(
            provider: CannedProvider(spamProbabilityByHost: ["spam.example": 0.99]), now: { Self.fixedNow }, log: { _ in })
        let outcome = await screener.screen(
            [try Self.interaction(id: "wm-s", host: "spam.example")],
            isAlreadyPublished: { _ in false },
            ownerRuling: { _ in OwnerRuling(approved: true, ruledAt: Self.fixedNow) })
        #expect(outcome.published.map(\.id) == ["wm-s"])
        #expect(outcome.decisions.first?.rule == .ownerRuling)
    }

    // MARK: - ledger

    @Test("ledger round-trips decisions and rulings, and lists the unresolved holds oldest first")
    func ledgerRoundTrip() throws {
        let configDir = try Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let ledger = InteractionScreeningLedger(configDirectory: configDir)
        #expect(ledger.load() == InteractionScreeningLedger.Contents())

        let later = Self.fixedNow.addingTimeInterval(60)
        ledger.record([
            ScreeningDecision(interactionID: "b", verdict: .hold, rule: .model, probabilitySpam: 0.7, confidence: 0.4,
                              scores: [log(0.7), log(0.3)], decidedAt: later),
            ScreeningDecision(interactionID: "a", verdict: .hold, rule: .model, probabilitySpam: 0.6, confidence: 0.2,
                              scores: [log(0.6), log(0.4)], decidedAt: Self.fixedNow),
            ScreeningDecision(interactionID: "c", verdict: .publish, rule: .noContent, decidedAt: Self.fixedNow),
        ])
        #expect(ledger.held().map(\.interactionID) == ["a", "b"])

        ledger.rule("a", approved: true, at: later)
        #expect(ledger.held().map(\.interactionID) == ["b"])
        #expect(ledger.ruling(for: "a") == OwnerRuling(approved: true, ruledAt: later))

        // A re-screen replaces the earlier decision for the same id.
        ledger.record([ScreeningDecision(interactionID: "b", verdict: .publish, rule: .ownerRuling, decidedAt: later)])
        #expect(ledger.held().isEmpty)
        #expect(ledger.load().decisions.count == 3)
        #expect(FileManager.default.fileExists(atPath: configDir.appendingPathComponent(InteractionScreeningLedger.fileName).path))
    }

    @Test("ledger yields calibration samples only for model decisions the owner ruled on")
    func ledgerCalibrationSamples() throws {
        let configDir = try Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let ledger = InteractionScreeningLedger(configDirectory: configDir)
        ledger.record([
            ScreeningDecision(interactionID: "spam", verdict: .hold, rule: .model, probabilitySpam: 0.8, confidence: 0.6,
                              scores: [log(0.8), log(0.2)], decidedAt: Self.fixedNow),
            ScreeningDecision(interactionID: "ham", verdict: .publish, rule: .model, probabilitySpam: 0.1, confidence: 0.8,
                              scores: [log(0.1), log(0.9)], decidedAt: Self.fixedNow),
            ScreeningDecision(interactionID: "unruled", verdict: .hold, rule: .model, probabilitySpam: 0.5, confidence: 0,
                              scores: [log(0.5), log(0.5)], decidedAt: Self.fixedNow),
            ScreeningDecision(interactionID: "vouched", verdict: .publish, rule: .verifiedVouch, decidedAt: Self.fixedNow),
        ])
        ledger.rule("spam", approved: false)
        ledger.rule("ham", approved: true)
        ledger.rule("vouched", approved: true)

        let samples = ledger.calibrationSamples().sorted { $0.correctIndex < $1.correctIndex }
        #expect(samples.count == 2)
        #expect(samples[0].correctIndex == 0 && abs(samples[0].logits[0] - log(0.8)) < 1e-12)
        #expect(samples[1].correctIndex == 1 && abs(samples[1].logits[1] - log(0.9)) < 1e-12)
    }

    @Test("a corrupt ledger file reads as empty rather than failing the sync")
    func corruptLedgerIsEmpty() throws {
        let configDir = try Self.tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try Data("not json".utf8).write(to: configDir.appendingPathComponent(InteractionScreeningLedger.fileName))
        let ledger = InteractionScreeningLedger(configDirectory: configDir)
        #expect(ledger.load() == InteractionScreeningLedger.Contents())
        #expect(ledger.held().isEmpty)
    }
}
