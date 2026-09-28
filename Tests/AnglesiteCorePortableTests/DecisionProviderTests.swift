// Lives in the portable target on purpose: the seam is pure Foundation, and this is the only
// test target the Linux CI leg executes (AnglesiteCoreTests isn't purity-swept — see
// Package.swift). Runs on macOS too, where it is plain coverage.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DecisionProvider seam")
struct DecisionProviderTests {

    /// Returns fixed logits per question prompt, so tests can drive the softmax exactly.
    private struct CannedScorer: OptionScorer {
        let logitsByPrompt: [String: [Double]]
        func score(state: String, question: DecisionQuestion) async throws -> [Double] {
            guard let logits = logitsByPrompt[question.prompt] else { throw DecisionError.unavailable("no canned logits") }
            return logits
        }
    }

    // MARK: - DecisionScoring

    @Test("softmax normalises, keeps order, and is stable for large logits")
    func softmaxBasics() {
        let p = DecisionScoring.softmax([1000, 1001, 999], temperature: 1)
        #expect(abs(p.reduce(0, +) - 1) < 1e-9)
        #expect(p[1] > p[0] && p[0] > p[2])
        #expect(p.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    @Test("temperature above 1 flattens, below 1 sharpens")
    func temperatureShapesDistribution() {
        let logits = [2.0, 0.0]
        let flat = DecisionScoring.answer(logits: logits, temperature: 4)
        let unit = DecisionScoring.answer(logits: logits, temperature: 1)
        let sharp = DecisionScoring.answer(logits: logits, temperature: 0.25)
        #expect(flat.confidence < unit.confidence)
        #expect(unit.confidence < sharp.confidence)
        #expect(flat.winnerIndex == 0 && sharp.winnerIndex == 0)
    }

    @Test("non-finite logits degrade to a uniform, zero-confidence answer")
    func nonFiniteLogitsAreUniform() {
        let answer = DecisionScoring.answer(logits: [-.infinity, -.infinity, .nan], temperature: 1)
        let third: Double = 1.0 / 3
        let uniform: [Double] = [third, third, third]
        #expect(answer.probabilities == uniform)
        #expect(answer.confidence == 0)
    }

    @Test("a noul answer's confidence is |2p − 1| and probabilityTrue is option 0")
    func noulConfidence() {
        let answer = DecisionAnswer(probabilities: [0.8, 0.2])
        #expect(abs(answer.confidence - 0.6) < 1e-12)
        #expect(answer.probabilityTrue == 0.8)
        #expect(answer.winnerIndex == 0)
    }

    @Test("ties resolve to the lowest index and a single option has confidence 1")
    func tiesAndSingletons() {
        #expect(DecisionAnswer(probabilities: [0.5, 0.5]).winnerIndex == 0)
        #expect(DecisionAnswer(probabilities: [1]).confidence == 1)
    }

    // MARK: - DecisionQuestion.validate

    @Test("validate rejects too few, too many, blank and duplicate options")
    func validateRejectsMalformedOptionSets() {
        #expect(throws: DecisionError.self) { try DecisionQuestion.choice(prompt: "k", options: ["only"]).validate() }
        #expect(throws: DecisionError.self) {
            try DecisionQuestion.score(prompt: "k", levels: (0..<11).map(String.init)).validate()
        }
        #expect(throws: DecisionError.self) { try DecisionQuestion.choice(prompt: "k", options: ["a", " "]).validate() }
        #expect(throws: DecisionError.self) { try DecisionQuestion.choice(prompt: "k", options: ["a", "a"]).validate() }
        #expect(throws: Never.self) { try DecisionQuestion.noul("spam?").validate() }
        #expect(throws: Never.self) { try DecisionQuestion.score(prompt: "k", levels: ["low", "mid", "high"]).validate() }
    }

    @Test("a noul question is always over the fixed yes/no option set")
    func noulOptions() {
        #expect(DecisionQuestion.noul("x").options == ["yes", "no"])
        #expect(DecisionQuestion.noul("x").prompt == "x")
    }

    // MARK: - ScoringDecisionProvider

    @Test("provider answers each question independently in order, applying its calibration")
    func providerComposesScorerAndCalibration() async throws {
        let scorer = CannedScorer(logitsByPrompt: ["spam?": [2, 0], "kind?": [0, 0, 3]])
        let provider = ScoringDecisionProvider(scorer: scorer, calibration: TemperatureCalibration(temperature: 2))
        let answers = try await provider.decide(
            state: "hello",
            questions: [.noul("spam?"), .choice(prompt: "kind?", options: ["a", "b", "c"])])
        #expect(answers.count == 2)
        #expect(answers[0].probabilities == DecisionScoring.softmax([2, 0], temperature: 2))
        #expect(answers[1].winnerIndex == 2)
    }

    @Test("provider validates before scoring and rejects a wrong-length score vector")
    func providerValidatesAndChecksLengths() async {
        let scorer = CannedScorer(logitsByPrompt: ["spam?": [1, 2, 3]])
        let provider = ScoringDecisionProvider(scorer: scorer)
        await #expect(throws: DecisionError.invalidQuestion("options must be distinct")) {
            _ = try await provider.decide(state: "s", questions: [.choice(prompt: "spam?", options: ["x", "x"])])
        }
        await #expect(throws: DecisionError.malformedScores(expected: 2, got: 3)) {
            _ = try await provider.decide(state: "s", questions: [.noul("spam?")])
        }
    }

    @Test("provider surfaces the scorer's unavailability unchanged")
    func providerPropagatesUnavailable() async {
        let provider = ScoringDecisionProvider(scorer: CannedScorer(logitsByPrompt: [:]))
        await #expect(throws: DecisionError.unavailable("no canned logits")) {
            _ = try await provider.decide(state: "s", questions: [.noul("anything")])
        }
    }
}
