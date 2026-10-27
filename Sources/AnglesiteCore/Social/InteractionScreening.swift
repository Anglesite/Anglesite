import Foundation

/// What the screen decided to do with one received interaction.
public enum ScreeningVerdict: String, Codable, Sendable, Equatable {
    /// Snapshot it into `Source/data/interactions/` as today — it renders on the site.
    case publish
    /// Keep it out of git and queue it for the owner (Website ▸ Moderation…). Nothing is
    /// deleted: the Worker's D1 inbox still holds it, and an owner Accept publishes it on the
    /// next sync.
    case hold
    /// Keep it out of git *without* queueing it. Off by default
    /// (``InteractionScreeningPolicy/dropThreshold`` is `nil`) until a site's own calibration
    /// report justifies it — an uncalibrated model must never make a comment silently vanish.
    case drop
}

/// The thresholds that turn a ``DecisionAnswer`` into a ``ScreeningVerdict``. Application code
/// owns these, per the System One rule that the model supplies narrow judgements and the program
/// decides what happens next; there is no per-site UI for them yet, so the defaults are the
/// product decision.
public struct InteractionScreeningPolicy: Sendable, Equatable {
    /// `p(spam)` at or above this is held for the owner.
    public var holdThreshold: Double
    /// `p(spam)` at or above this is dropped outright. `nil` disables dropping entirely.
    public var dropThreshold: Double?
    /// Below this ``DecisionAnswer/confidence`` the model's answer isn't trusted either way and the
    /// interaction is held — the escalation gate: uncertain cases go to a person.
    public var minimumConfidence: Double
    /// How much of `content` reaches the model. The Worker already truncates to ~500 characters;
    /// this is a second guard so a future longer field can't blow past a small on-device model's
    /// context window.
    public var maxContentCharacters: Int

    /// The shipped defaults: hold at 50% spam probability or below 30% confidence, never drop.
    public static let `default` = InteractionScreeningPolicy(
        holdThreshold: 0.5, dropThreshold: nil, minimumConfidence: 0.3, maxContentCharacters: 1500)

    public init(holdThreshold: Double, dropThreshold: Double?, minimumConfidence: Double, maxContentCharacters: Int) {
        self.holdThreshold = holdThreshold
        self.dropThreshold = dropThreshold
        self.minimumConfidence = minimumConfidence
        self.maxContentCharacters = max(0, maxContentCharacters)
    }
}

/// The owner's explicit ruling on one interaction, recorded from the moderation pane. Wins over
/// every other rule, and doubles as a calibration label (``InteractionScreeningLedger/calibrationSamples()``).
public struct OwnerRuling: Codable, Sendable, Equatable {
    /// `true` publishes the interaction; `false` keeps it held.
    public let approved: Bool
    /// When the owner ruled.
    public let ruledAt: Date

    public init(approved: Bool, ruledAt: Date) {
        self.approved = approved
        self.ruledAt = ruledAt
    }
}

/// One screening decision, with enough of the model's output kept to explain it in the
/// moderation pane and to fit ``TemperatureCalibration`` later.
public struct ScreeningDecision: Codable, Sendable, Equatable {
    /// Which rule produced the verdict — a deterministic pre-filter or the model.
    public enum Rule: String, Codable, Sendable, Equatable {
        /// The owner already ruled on this interaction (``OwnerRuling``).
        case ownerRuling
        /// It was already snapshotted in git before screening existed; grandfathered so
        /// enabling the screen never un-publishes a comment the site has been showing.
        case alreadyPublished
        /// The sender's Vouch was verified by the Worker — an inbound-trust signal the
        /// IndieWeb already defines, so no model judgement is needed.
        case verifiedVouch
        /// There is no text to judge (a like, a repost, a bare mention); text-only screening
        /// has nothing to say, so today's behavior (publish) stands.
        case noContent
        /// The model answered and the policy thresholds decided.
        case model
        /// The model threw ``DecisionError``; fail-open to today's behavior, logged.
        case modelUnavailable
    }

    public let interactionID: String
    public let verdict: ScreeningVerdict
    public let rule: Rule
    /// `p(spam)` from the model; `nil` for a deterministic rule.
    public let probabilitySpam: Double?
    /// ``DecisionAnswer/confidence`` from the model; `nil` for a deterministic rule.
    public let confidence: Double?
    /// The provider's raw (yes, no) scores behind `probabilitySpam`, before any temperature
    /// (``DecisionAnswer/logits``) — what a later ``TemperatureCalibration/fit(samples:)``
    /// needs, and deliberately *not* the log of the reported probabilities: those already carry
    /// the site temperature in force at the time, so fitting on them would bake each fit into
    /// the next. `nil` for a deterministic rule, or for a provider that doesn't expose its
    /// scores; such decisions don't feed calibration.
    public let scores: [Double]?
    public let decidedAt: Date

    public init(
        interactionID: String, verdict: ScreeningVerdict, rule: Rule,
        probabilitySpam: Double? = nil, confidence: Double? = nil, scores: [Double]? = nil,
        decidedAt: Date
    ) {
        self.interactionID = interactionID
        self.verdict = verdict
        self.rule = rule
        self.probabilitySpam = probabilitySpam
        self.confidence = confidence
        self.scores = scores
        self.decidedAt = decidedAt
    }
}

/// The result of screening one batch: what to commit, what to queue, and every decision made.
public struct ScreeningOutcome: Sendable, Equatable {
    /// Interactions to snapshot into git, in input order.
    public let published: [ReceivedInteraction]
    /// Interactions held for the owner, in input order.
    public let held: [ReceivedInteraction]
    /// Interactions dropped, in input order. Empty unless the policy enables dropping.
    public let dropped: [ReceivedInteraction]
    /// One decision per input interaction, in input order.
    public let decisions: [ScreeningDecision]
}

/// The spam/abuse gate in front of ``ReceivedInteractionCommitter``: deterministic rules first,
/// then one narrow yes/no question to a ``DecisionProvider``, then policy thresholds. Design:
/// `docs/superpowers/specs/2026-09-28-system-one-decision-seam-design.md`.
///
/// Fail-open by construction: an unavailable model, a thrown error, or a `nil` screener at the
/// call site all reduce to today's behavior (publish everything). The screen can only ever *add*
/// a hold, never lose an interaction — D1 remains the operational store.
public struct InteractionScreener: Sendable {
    /// The one question the screen asks. Phrased as a proposition so the "yes" probability is
    /// directly `p(spam)`; deliberately narrow (no "is it rude?", no "is it on-topic?") so the
    /// answer stays a single calibratable signal.
    public static let spamQuestion = DecisionQuestion.noul(
        "This interaction is spam, unsolicited advertising, or abuse, rather than a genuine "
        + "response to the page it targets.")

    private let provider: any DecisionProvider
    private let policy: InteractionScreeningPolicy
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) async -> Void

    /// Creates a screener.
    ///
    /// - Parameters:
    ///   - provider: Answers ``InteractionScreener/spamQuestion``. Its errors are caught and fail open.
    ///   - policy: Thresholds; see ``InteractionScreeningPolicy/default``.
    ///   - now: Clock for ``ScreeningDecision/decidedAt``; injectable for tests.
    ///   - log: Where a model failure is reported. `nil` (the default) means `LogCenter` (the
    ///     debug pane) — "logs are sacred": a silently-skipped screen would look identical to a
    ///     clean one. Optional rather than a defaulted closure literal for the #1990 reason noted
    ///     in `ReceivedInteractionCommitter.commit`: an async closure default is re-emitted per
    ///     client module and the linker can mix the copies.
    public init(
        provider: any DecisionProvider,
        policy: InteractionScreeningPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        log: (@Sendable (String) async -> Void)? = nil
    ) {
        self.provider = provider
        self.policy = policy
        self.now = now
        self.log = log ?? { text in
            await LogCenter.shared.append(source: "InteractionScreener", stream: .stderr, text: text)
        }
    }

    /// The text the model sees for one interaction: a small labelled record, not raw JSON, so a
    /// compact on-device model spends its window on the content rather than on field names.
    /// `content` is truncated to `policy.maxContentCharacters`.
    public static func state(for interaction: ReceivedInteraction, policy: InteractionScreeningPolicy = .default) -> String {
        var lines: [String] = []
        lines.append("Protocol: \(interaction.type.rawValue)")
        lines.append("Kind: \(interaction.interactionType.rawValue)")
        lines.append("From: \(interaction.source.absoluteString)")
        if let author = interaction.author {
            var who: [String] = []
            if let name = author.name, !name.isEmpty { who.append(name) }
            if let url = author.url { who.append(url.absoluteString) }
            if !who.isEmpty { lines.append("Author: \(who.joined(separator: " — "))") }
        }
        lines.append("To: \(interaction.target.absoluteString)")
        if let vouch = interaction.vouch {
            lines.append("Vouch: \(vouch.url.absoluteString) (\(vouch.verified ? "verified" : "not verified"))")
        }
        if let content = interaction.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            lines.append("Content:")
            lines.append(String(content.prefix(policy.maxContentCharacters)))
        }
        return lines.joined(separator: "\n")
    }

    /// Screens `interactions` in order.
    ///
    /// - Parameters:
    ///   - interactions: The full current verified set from the Worker.
    ///   - isAlreadyPublished: Whether a snapshot for this id already exists in git; such
    ///     interactions are grandfathered (``ScreeningDecision/Rule/alreadyPublished``).
    ///   - ownerRuling: The owner's prior ruling for this id, if any; it wins over every rule.
    /// - Returns: The partitioned batch and one decision per input.
    public func screen(
        _ interactions: [ReceivedInteraction],
        isAlreadyPublished: @Sendable (String) -> Bool,
        ownerRuling: @Sendable (String) -> OwnerRuling?
    ) async -> ScreeningOutcome {
        var published: [ReceivedInteraction] = []
        var held: [ReceivedInteraction] = []
        var dropped: [ReceivedInteraction] = []
        var decisions: [ScreeningDecision] = []
        var reportedFailure = false

        for interaction in interactions {
            let decision: ScreeningDecision
            if let ruling = ownerRuling(interaction.id) {
                decision = ScreeningDecision(
                    interactionID: interaction.id, verdict: ruling.approved ? .publish : .hold,
                    rule: .ownerRuling, decidedAt: now())
            } else if isAlreadyPublished(interaction.id) {
                decision = ScreeningDecision(
                    interactionID: interaction.id, verdict: .publish, rule: .alreadyPublished, decidedAt: now())
            } else if interaction.vouch?.verified == true {
                decision = ScreeningDecision(
                    interactionID: interaction.id, verdict: .publish, rule: .verifiedVouch, decidedAt: now())
            } else if (interaction.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decision = ScreeningDecision(
                    interactionID: interaction.id, verdict: .publish, rule: .noContent, decidedAt: now())
            } else {
                do {
                    let answers = try await provider.decide(
                        state: Self.state(for: interaction, policy: policy), questions: [Self.spamQuestion])
                    guard let answer = answers.first, answer.probabilities.count == 2 else {
                        throw DecisionError.malformedScores(expected: 2, got: answers.first?.probabilities.count ?? 0)
                    }
                    decision = ScreeningDecision(
                        interactionID: interaction.id, verdict: Self.verdict(for: answer, policy: policy),
                        rule: .model, probabilitySpam: answer.probabilityTrue, confidence: answer.confidence,
                        scores: answer.logits, decidedAt: now())
                } catch {
                    if !reportedFailure {
                        reportedFailure = true
                        await log("Spam screening unavailable; publishing this batch unscreened: \(error)")
                    }
                    decision = ScreeningDecision(
                        interactionID: interaction.id, verdict: .publish, rule: .modelUnavailable, decidedAt: now())
                }
            }
            decisions.append(decision)
            switch decision.verdict {
            case .publish: published.append(interaction)
            case .hold: held.append(interaction)
            case .drop: dropped.append(interaction)
            }
        }
        return ScreeningOutcome(published: published, held: held, dropped: dropped, decisions: decisions)
    }

    /// Maps one answer to ``InteractionScreener/spamQuestion`` onto a verdict under `policy`: drop (if enabled) beats
    /// hold beats the low-confidence hold beats publish. Pure, so the threshold logic is testable
    /// without a provider.
    public static func verdict(for answer: DecisionAnswer, policy: InteractionScreeningPolicy) -> ScreeningVerdict {
        let p = answer.probabilityTrue
        if let drop = policy.dropThreshold, p >= drop, answer.confidence >= policy.minimumConfidence {
            return .drop
        }
        if p >= policy.holdThreshold { return .hold }
        if answer.confidence < policy.minimumConfidence { return .hold }
        return .publish
    }
}

/// App-owned record of screening decisions and owner rulings for one site, at
/// `Config/interaction-screening.json` — beside `settings.plist`, never in the site's git repo
/// (decision D6: infrastructure state lives in `Config/`). The moderation pane reads
/// ``InteractionScreeningLedger/held()`` from here; an owner Accept/Reject writes an ``OwnerRuling`` here; and the pairs of
/// model decision + owner ruling are the labelled set ``TemperatureCalibration`` fits on.
public struct InteractionScreeningLedger: Sendable {
    /// On-disk shape. Versioned so a later change to ``ScreeningDecision`` can migrate.
    public struct Contents: Codable, Sendable, Equatable {
        public var version: Int
        /// Latest decision per interaction id.
        public var decisions: [String: ScreeningDecision]
        /// Owner rulings per interaction id.
        public var rulings: [String: OwnerRuling]

        public init(version: Int = 1, decisions: [String: ScreeningDecision] = [:], rulings: [String: OwnerRuling] = [:]) {
            self.version = version
            self.decisions = decisions
            self.rulings = rulings
        }
    }

    /// The file name under `Config/`.
    public static let fileName = "interaction-screening.json"

    private let store: CodableFileStore<Contents>

    /// Points the ledger at `<configDirectory>/interaction-screening.json`.
    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.store = .json(
            fileURL: configDirectory.appendingPathComponent(Self.fileName),
            fileManager: fileManager,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601)
    }

    /// Everything on disk, or an empty ledger when the file is missing or unreadable — a lost
    /// ledger only means the next sync re-screens, which is safe (grandfathering still applies).
    public func load() -> Contents {
        store.loadOrDefault(Contents())
    }

    /// The owner's ruling for `id`, if any.
    public func ruling(for id: String) -> OwnerRuling? {
        load().rulings[id]
    }

    /// Records the latest decision for each interaction in `decisions`, replacing any earlier
    /// decision for the same id. Best-effort: a failed write is swallowed, since the snapshot
    /// commit that already happened is what matters and the next sync re-screens anyway.
    public func record(_ decisions: [ScreeningDecision]) {
        var contents = load()
        for decision in decisions { contents.decisions[decision.interactionID] = decision }
        try? store.save(contents)
    }

    /// Records the owner's ruling for `id`. Idempotent; a later ruling replaces an earlier one.
    public func rule(_ id: String, approved: Bool, at date: Date = Date()) {
        var contents = load()
        contents.rulings[id] = OwnerRuling(approved: approved, ruledAt: date)
        try? store.save(contents)
    }

    /// Ids currently held for the owner: decided `.hold` and not yet ruled on. Sorted by decision
    /// time, oldest first, so the queue is stable across reloads.
    public func held() -> [ScreeningDecision] {
        let contents = load()
        return contents.decisions.values
            .filter { $0.verdict == .hold && contents.rulings[$0.interactionID] == nil }
            .sorted { $0.decidedAt < $1.decidedAt }
    }

    /// Labelled samples for ``TemperatureCalibration/fit(samples:)``: every model decision with
    /// `scores` that the owner later ruled on. Owner Reject means the spam
    /// proposition was true (option 0, "yes"); Accept means it was false (option 1).
    public func calibrationSamples() -> [TemperatureCalibration.Sample] {
        let contents = load()
        return contents.decisions.values.compactMap { decision in
            guard decision.rule == .model, let scores = decision.scores, scores.count == 2,
                  let ruling = contents.rulings[decision.interactionID]
            else { return nil }
            return TemperatureCalibration.Sample(logits: scores, correctIndex: ruling.approved ? 1 : 0)
        }
    }
}
