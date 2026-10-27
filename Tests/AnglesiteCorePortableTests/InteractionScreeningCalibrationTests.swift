// Portable-target test (pure Foundation) so the Linux CI leg executes it — see
// DecisionProviderTests for the rationale.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("InteractionScreeningCalibrationStore (#2067)")
struct InteractionScreeningCalibrationTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// Same deterministic LCG as TemperatureCalibrationTests, so the synthetic ledger is
    /// identical on every run and platform.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static func temporaryConfigDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionScreeningCalibrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fills `ledger` with `count` model decisions whose (yes, no) scores are over-confident by
    /// `trueTemperature`, each ruled on by the owner according to a label drawn at that
    /// temperature: Reject (not approved) when "yes, spam" was true, Accept otherwise.
    private static func populate(_ ledger: InteractionScreeningLedger, count: Int, trueTemperature: Double, seed: UInt64 = 7) {
        var rng = LCG(state: seed)
        var decisions: [ScreeningDecision] = []
        var rulings: [(String, Bool)] = []
        for index in 0..<count {
            let logits = [rng.next() * 8 - 4, rng.next() * 8 - 4]
            let truth = DecisionScoring.softmax(logits, temperature: trueTemperature)
            let spamWasTrue = rng.next() < truth[0]
            let id = "m\(index)"
            decisions.append(ScreeningDecision(
                interactionID: id, verdict: .hold, rule: .model,
                probabilitySpam: DecisionScoring.softmax(logits, temperature: 1)[0], confidence: 0.5,
                scores: logits, decidedAt: now.addingTimeInterval(Double(index))))
            rulings.append((id, !spamWasTrue))
        }
        ledger.record(decisions)
        for (id, approved) in rulings { ledger.rule(id, approved: approved, at: now) }
    }

    @Test("below the minimum sample count nothing is fitted and the site calibration stays identity")
    func belowThresholdStaysIdentity() async throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: TemperatureCalibration.minimumSamples - 1, trueTemperature: 3)
        let store = InteractionScreeningCalibrationStore(configDirectory: dir)
        #expect(store.refit(from: ledger) == nil)
        #expect(store.load() == nil)
        #expect(store.current == .identity)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(InteractionScreeningCalibrationStore.fileName).path))
        #expect(await InteractionScreenerFactory.siteCalibration(configDirectory: dir) == .identity)
    }

    @Test("a ledger of over-confident scores fits a temperature above 1 and lowers ECE")
    func overConfidentLedgerFitsAboveOne() throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: 150, trueTemperature: 3)
        let store = InteractionScreeningCalibrationStore(configDirectory: dir)
        let report = try #require(store.refit(from: ledger))
        #expect(report.sampleCount == 150)
        #expect(report.previous == .identity)
        #expect(report.fitted.temperature > 1.5)
        #expect(report.errorAfter < report.errorBefore)
        #expect(report.summary.hasPrefix("Screening calibration: T = "))
        #expect(report.summary.contains("from 150 rulings"))
        // Persisted, and a second refit is idempotent: same fit, now reported as the previous one.
        #expect(store.load() == report.fitted)
        let again = try #require(store.refit(from: ledger))
        #expect(again.fitted == report.fitted)
        #expect(again.previous == report.fitted)
    }

    @Test("the persisted calibration file round-trips")
    func persistedFileRoundTrips() throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InteractionScreeningCalibrationStore(configDirectory: dir)
        let calibration = TemperatureCalibration(temperature: 1.375)
        try store.save(calibration)
        #expect(store.load() == calibration)
        #expect(InteractionScreeningCalibrationStore(configDirectory: dir).current == calibration)
        let data = try Data(contentsOf: dir.appendingPathComponent(InteractionScreeningCalibrationStore.fileName))
        #expect(String(decoding: data, as: UTF8.self).contains("\"temperature\""))
    }

    private actor LineRecorder {
        var lines: [String] = []
        func record(_ line: String) { lines.append(line) }
    }

    private struct CannedScorer: OptionScorer {
        let logits: [Double]
        func score(state: String, question: DecisionQuestion) async throws -> [Double] { logits }
    }

    /// A scorer whose raw logits depend on the interaction, keyed by a marker in its content.
    private struct KeyedScorer: OptionScorer {
        let logitsByMarker: [String: [Double]]
        func score(state: String, question: DecisionQuestion) async throws -> [Double] {
            guard let marker = logitsByMarker.keys.first(where: { state.contains($0) }) else {
                throw DecisionError.unavailable("no logits for state")
            }
            return logitsByMarker[marker]!
        }
    }

    private static func interaction(_ id: String, content: String) throws -> ReceivedInteraction {
        try ReceivedInteraction(
            id: id, type: .webmention, source: URL(string: "https://sender.example/\(id)")!,
            target: URL(string: "https://me.example/blog/hi")!, interactionType: .reply,
            author: .init(name: "Sender", url: nil, photo: nil), content: content,
            published: now, verified: now, verificationStatus: .verified)
    }

    @Test("rows screened under a fitted temperature refit to the same temperature, not a compounded one")
    func refitIsStableAcrossFits() async throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: 150, trueTemperature: 3)
        let store = InteractionScreeningCalibrationStore(configDirectory: dir)
        let first = try #require(store.refit(from: ledger)).fitted
        #expect(first.temperature > 1.5)

        // A second era: 150 more interactions screened by a provider that *applies* `first`, the
        // way the app's screener would after the fit landed, labelled at the same true T.
        var rng = LCG(state: 99)
        var logitsByMarker: [String: [Double]] = [:]
        var interactions: [ReceivedInteraction] = []
        var rulings: [(String, Bool)] = []
        for index in 0..<150 {
            let logits = [rng.next() * 8 - 4, rng.next() * 8 - 4]
            let marker = "era2-item-\(index)-"
            logitsByMarker[marker] = logits
            interactions.append(try Self.interaction("e\(index)", content: "\(marker) hello"))
            let spamWasTrue = rng.next() < DecisionScoring.softmax(logits, temperature: 3)[0]
            rulings.append(("e\(index)", !spamWasTrue))
        }
        let provider = ScoringDecisionProvider(scorer: KeyedScorer(logitsByMarker: logitsByMarker), calibration: first)
        let screener = InteractionScreener(provider: provider, now: { Self.now }, log: { _ in })
        let outcome = await screener.screen(interactions, isAlreadyPublished: { _ in false }, ownerRuling: { _ in nil })
        #expect(outcome.decisions.count == 150)
        // What the ledger keeps is the raw logits, untouched by `first`.
        let sample = try #require(outcome.decisions.first { $0.interactionID == "e0" })
        #expect(sample.rule == .model)
        #expect(sample.scores == logitsByMarker["era2-item-0-"])
        ledger.record(outcome.decisions)
        for (id, approved) in rulings { ledger.rule(id, approved: approved, at: Self.now) }

        let second = try #require(store.refit(from: ledger))
        #expect(second.sampleCount == 300)
        #expect(second.previous == first)
        // Same true temperature (3) behind both eras, so the pooled refit stays near it and near
        // the first fit. Had the screener recorded log-probabilities, the second era's scores
        // would already be divided by `first`, its own fit would come out near 3 / first ≈ 1.5,
        // and the pooled fit would drift down toward 2 — and lower on every refit after that.
        #expect(second.fitted.temperature > 2.2 && second.fitted.temperature < 4)
        #expect(abs(second.fitted.temperature - first.temperature) < 0.35 * first.temperature)
        let eraTwoLogits = Set(logitsByMarker.values.map { $0.map { $0.bitPattern } })
        let eraTwo = TemperatureCalibration.fit(
            samples: ledger.calibrationSamples().filter { eraTwoLogits.contains($0.logits.map(\.bitPattern)) })
        #expect(eraTwo.temperature > 2.2 && eraTwo.temperature < 5)
    }

    @Test("the factory applies the site's fit on top of the scorer and logs one report line")
    func factoryPicksUpSiteCalibration() async throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: 150, trueTemperature: 3)
        let recorder = LineRecorder()
        let calibration = await InteractionScreenerFactory.siteCalibration(configDirectory: dir) { line in
            await recorder.record(line)
        }
        #expect(calibration.temperature > 1.5)
        #expect(calibration == InteractionScreeningCalibrationStore(configDirectory: dir).current)
        let lines = await recorder.lines
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("Screening calibration: T = ") == true)

        // Composed onto a scorer, the fitted temperature softens the same logits' confidence.
        let scorer = CannedScorer(logits: [3, -1])
        let question = DecisionQuestion.noul("This interaction is spam.")
        let raw = try await ScoringDecisionProvider(scorer: scorer).decide(state: "s", questions: [question])[0]
        let calibrated = try await ScoringDecisionProvider(scorer: scorer, calibration: calibration)
            .decide(state: "s", questions: [question])[0]
        #expect(calibrated.confidence < raw.confidence)
        #expect(calibrated.winnerIndex == raw.winnerIndex)
    }
}
