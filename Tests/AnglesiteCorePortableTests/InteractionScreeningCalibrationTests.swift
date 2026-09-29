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
    func belowThresholdStaysIdentity() throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: TemperatureCalibration.minimumSamples - 1, trueTemperature: 3)
        let store = InteractionScreeningCalibrationStore(configDirectory: dir)
        #expect(store.refit(from: ledger) == nil)
        #expect(store.load() == nil)
        #expect(store.current == .identity)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(InteractionScreeningCalibrationStore.fileName).path))
        #expect(InteractionScreenerFactory.siteCalibration(configDirectory: dir) == .identity)
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

    @Test("the factory applies the site's fit on top of the scorer and logs one report line")
    func factoryPicksUpSiteCalibration() async throws {
        let dir = try Self.temporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = InteractionScreeningLedger(configDirectory: dir)
        Self.populate(ledger, count: 150, trueTemperature: 3)
        let recorder = LineRecorder()
        let calibration = InteractionScreenerFactory.siteCalibration(configDirectory: dir) { line in
            await recorder.record(line)
        }
        #expect(calibration.temperature > 1.5)
        #expect(calibration == InteractionScreeningCalibrationStore(configDirectory: dir).current)
        // The log line is dispatched on a detached task; give it a moment.
        for _ in 0..<50 where await recorder.lines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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
