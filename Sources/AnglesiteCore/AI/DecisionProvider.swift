import Foundation

/// One typed question a ``DecisionProvider`` answers against a piece of state. The three shapes
/// are the "System One" primitives (TypeSafe's Jev vocabulary — see
/// `docs/superpowers/specs/2026-09-28-system-one-decision-seam-design.md`): every answer is a
/// probability distribution over an option set the *caller* fixed in advance, never free text, so
/// application code can branch on it directly and own every threshold and side effect.
public enum DecisionQuestion: Sendable, Equatable {
    /// A yes/no proposition ("this comment is spam"). Answered as the probability the proposition
    /// is true; the option set is fixed to ``DecisionQuestion/noulOptions``.
    case noul(String)
    /// Pick one of `options` (2…255, distinct, non-empty) for `prompt`.
    case choice(prompt: String, options: [String])
    /// Place the state on an *ordered* rubric of `levels` (2…10, lowest first) for `prompt`.
    case score(prompt: String, levels: [String])

    /// The fixed option set every ``DecisionQuestion/noul(_:)`` answer is expressed over, in this order.
    public static let noulOptions = ["yes", "no"]

    /// The prompt text, whichever shape the question is.
    public var prompt: String {
        switch self {
        case .noul(let proposition): return proposition
        case .choice(let prompt, _), .score(let prompt, _): return prompt
        }
    }

    /// The option set an answer to this question is a distribution over, in the order
    /// ``DecisionAnswer/probabilities`` is indexed by.
    public var options: [String] {
        switch self {
        case .noul: return Self.noulOptions
        case .choice(_, let options): return options
        case .score(_, let levels): return levels
        }
    }

    /// Throws when the option set can't be answered over: too few / too many options, a blank
    /// option, or duplicates. Checked by ``ScoringDecisionProvider`` before any model call so a
    /// malformed question fails loudly rather than producing a distribution nothing can index.
    public func validate() throws {
        let options = self.options
        let (lower, upper): (Int, Int) = {
            switch self {
            case .noul: return (2, 2)
            case .choice: return (2, 255)
            case .score: return (2, 10)
            }
        }()
        guard (lower...upper).contains(options.count) else {
            throw DecisionError.invalidQuestion("expected \(lower)…\(upper) options, got \(options.count)")
        }
        guard options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecisionError.invalidQuestion("options must be non-empty")
        }
        guard Set(options).count == options.count else {
            throw DecisionError.invalidQuestion("options must be distinct")
        }
    }
}

/// The typed answer to one ``DecisionQuestion``: a full distribution over the question's options
/// plus the winner and a confidence, so callers can gate on either ("publish if p(spam) < 0.2",
/// "hold for the owner if confidence < 0.6") without re-deriving anything.
public struct DecisionAnswer: Sendable, Equatable {
    /// Probability per option, in the question's option order. Sums to 1 (within floating-point
    /// error); every entry is in 0…1.
    public let probabilities: [Double]
    /// The option with the highest probability (the lowest index on a tie).
    public let winnerIndex: Int
    /// How separated the winner is from the runner-up: the probability margin between the top two
    /// options, in 0…1. For a ``DecisionQuestion/noul(_:)`` this is `|2·p(yes) − 1|`. It is a
    /// *calibrated* uncertainty signal only to the extent the provider's temperature was fitted
    /// (``TemperatureCalibration``); it never guarantees an individual answer is right.
    public let confidence: Double
    /// The provider's raw option scores, in option order, *before* any temperature was applied —
    /// present when the provider exposes them (``ScoringDecisionProvider`` does), `nil` when it
    /// only produces probabilities. This is what the screening ledger records for
    /// ``TemperatureCalibration/fit(samples:)``: fitting on `log(probabilities)` instead would
    /// bake the current temperature into its own labelled set, so every refit would compound
    /// on the last (#2083 review).
    public let logits: [Double]?

    /// Builds an answer from an already-normalised distribution. Callers should go through
    /// ``DecisionScoring/answer(logits:temperature:)`` rather than constructing one by hand; this
    /// initializer exists for test fakes and for providers that already produce probabilities.
    ///
    /// - Precondition: `probabilities` is non-empty.
    public init(probabilities: [Double], logits: [Double]? = nil) {
        precondition(!probabilities.isEmpty, "a DecisionAnswer needs at least one option")
        self.probabilities = probabilities
        self.logits = logits
        var winner = 0
        for (index, p) in probabilities.enumerated() where p > probabilities[winner] { winner = index }
        self.winnerIndex = winner
        let sorted = probabilities.sorted(by: >)
        self.confidence = sorted.count > 1 ? max(0, min(1, sorted[0] - sorted[1])) : 1
    }

    /// For a ``DecisionQuestion/noul(_:)`` answer, the probability the proposition is true —
    /// `probabilities[0]`, since ``DecisionQuestion/noulOptions`` puts "yes" first.
    public var probabilityTrue: Double { probabilities[0] }
}

/// Failures a ``DecisionProvider`` can surface.
public enum DecisionError: Error, Equatable, Sendable {
    /// No decision model is available on this host (asset not downloaded, unsupported platform).
    /// Callers degrade to their pre-model behavior — for the interaction screen, publish
    /// everything, as today — rather than failing the operation.
    case unavailable(String)
    /// The question's option set is malformed; see ``DecisionQuestion/validate()``.
    case invalidQuestion(String)
    /// The scorer returned a logit vector whose length doesn't match the question's options.
    case malformedScores(expected: Int, got: Int)
}

/// Answers typed questions about a piece of state. The seam ``InteractionScreener`` (and any
/// future gate) depends on, so the model behind it — a Core ML readout-head model in production,
/// a canned fake in tests — is swappable without touching the code that owns the thresholds.
///
/// Questions in one call are evaluated **independently** against the same `state`: the answer to
/// one never becomes context for another. That is what lets a caller ask several narrow questions
/// in parallel and combine them in code, instead of one compound question a model must reason
/// through.
public protocol DecisionProvider: Sendable {
    /// Evaluates every question against `state`, returning one answer per question in order.
    ///
    /// - Parameters:
    ///   - state: Everything the judgement should see — the material you'd put in front of a
    ///     panel of reviewers. Plain text; callers serialise structured records themselves.
    ///   - questions: The typed questions to answer, each validated per
    ///     ``DecisionQuestion/validate()``.
    /// - Returns: One ``DecisionAnswer`` per question, indexed like `questions`.
    /// - Throws: ``DecisionError`` when the model is unavailable or a question is malformed.
    func decide(state: String, questions: [DecisionQuestion]) async throws -> [DecisionAnswer]
}

/// Scores a question's options against state and returns one raw, unnormalised score (a logit)
/// per option, in option order. This is the narrow surface a model backend implements — a Core ML
/// model reading logits at the option positions of a single prefill, or a test fake — while
/// ``ScoringDecisionProvider`` turns the scores into a calibrated ``DecisionAnswer``.
public protocol OptionScorer: Sendable {
    /// Returns exactly `question.options.count` scores for `question` evaluated against `state`.
    ///
    /// - Throws: ``DecisionError/unavailable(_:)`` when the backing model can't be loaded.
    func score(state: String, question: DecisionQuestion) async throws -> [Double]
}

/// A ``DecisionProvider`` assembled from an ``OptionScorer`` and a ``TemperatureCalibration``:
/// validate → score → temperature-scaled restricted softmax. This is the composition every real
/// backend uses, so calibration lives in one place regardless of which model produced the scores.
public struct ScoringDecisionProvider: DecisionProvider {
    private let scorer: any OptionScorer
    private let calibration: TemperatureCalibration

    /// Creates a provider over `scorer`. `calibration` defaults to the identity temperature; fit
    /// one with ``TemperatureCalibration/fit(samples:)`` on labelled data before trusting
    /// ``DecisionAnswer/confidence`` as a gate.
    public init(scorer: any OptionScorer, calibration: TemperatureCalibration = .identity) {
        self.scorer = scorer
        self.calibration = calibration
    }

    public func decide(state: String, questions: [DecisionQuestion]) async throws -> [DecisionAnswer] {
        for question in questions { try question.validate() }
        var answers: [DecisionAnswer] = []
        answers.reserveCapacity(questions.count)
        for question in questions {
            let logits = try await scorer.score(state: state, question: question)
            guard logits.count == question.options.count else {
                throw DecisionError.malformedScores(expected: question.options.count, got: logits.count)
            }
            answers.append(DecisionScoring.answer(logits: logits, temperature: calibration.temperature))
        }
        return answers
    }
}

/// The restricted-softmax step shared by every scorer-backed provider (and by the clones this
/// seam is modelled on — `openjev`, `open-alternative-jev`, `kev`): the only tokens that can win
/// are the caller's options, so a type-invalid answer is unrepresentable by construction.
public enum DecisionScoring {
    /// Turns raw option scores into a ``DecisionAnswer`` via `softmax(logits / temperature)`.
    ///
    /// - Parameters:
    ///   - logits: One unnormalised score per option, in option order. Non-empty.
    ///   - temperature: Positive scale applied before the softmax; `1` leaves the model's own
    ///     confidence as-is, `> 1` flattens it, `< 1` sharpens it. Non-positive values are clamped
    ///     to a tiny epsilon rather than trapping, so a corrupt calibration file degrades to a
    ///     near-argmax answer instead of a crash.
    /// - Returns: The normalised distribution with winner and confidence filled in.
    public static func answer(logits: [Double], temperature: Double) -> DecisionAnswer {
        DecisionAnswer(probabilities: softmax(logits, temperature: temperature), logits: logits)
    }

    /// Numerically stable softmax over `logits / temperature`. Exposed for
    /// ``TemperatureCalibration``'s fit loop; `answer(logits:temperature:)` is the normal entry.
    public static func softmax(_ logits: [Double], temperature: Double) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let t = max(temperature, 1e-6)
        let scaled = logits.map { $0 / t }
        let peak = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - peak) }
        let sum = exps.reduce(0, +)
        guard sum > 0, sum.isFinite else {
            // Every score was −∞/NaN; fall back to uniform so a caller still gets a valid
            // distribution (and a zero-confidence answer that any gate will hold for review).
            return [Double](repeating: 1 / Double(logits.count), count: logits.count)
        }
        return exps.map { $0 / sum }
    }
}
