import Foundation

/// The five delimiter token ids Kev repurposes from Qwen's reserved vocabulary, in the order Kev's
/// `SPECIAL` list gives them: `<|fim_prefix|>` opens the state, `<|fim_middle|>` opens a question,
/// `<|box_start|>` / `<|box_end|>` bracket an option, `<|fim_suffix|>` is the `<decide>` token
/// whose hidden state the pointer head reads. Loaded from the checkpoint's `added_tokens.json`
/// rather than hardcoded, so a retrained checkpoint with a different reserved set still works.
public struct KevDelimiters: Codable, Sendable, Equatable {
    public let state: Int32
    public let question: Int32
    public let optionOpen: Int32
    public let optionClose: Int32
    public let decide: Int32

    /// The token strings Kev's `SPECIAL` list names, in ``init(state:question:optionOpen:optionClose:decide:)`` order.
    public static let specialTokens = ["<|fim_prefix|>", "<|fim_middle|>", "<|box_start|>", "<|box_end|>", "<|fim_suffix|>"]

    public init(state: Int32, question: Int32, optionOpen: Int32, optionClose: Int32, decide: Int32) {
        self.state = state
        self.question = question
        self.optionOpen = optionOpen
        self.optionClose = optionClose
        self.decide = decide
    }

    /// Reads the five ids out of a Hugging Face `added_tokens.json` (`{token: id}`).
    ///
    /// - Throws: ``KevPackingError/missingDelimiter(_:)`` naming the first token not present.
    public init(addedTokens: [String: Int32]) throws {
        var ids: [Int32] = []
        for token in Self.specialTokens {
            guard let id = addedTokens[token] else { throw KevPackingError.missingDelimiter(token) }
            ids.append(id)
        }
        self.init(state: ids[0], question: ids[1], optionOpen: ids[2], optionClose: ids[3], decide: ids[4])
    }
}

/// Failures while packing a record.
public enum KevPackingError: Error, Equatable, Sendable {
    /// `added_tokens.json` lacks one of ``KevDelimiters/specialTokens``.
    case missingDelimiter(String)
    /// A question's branch (instruction + options + decide) doesn't fit beside the state within
    /// the row limit; mirrors Kev's `ContextOverflow`. The state itself is silently truncated
    /// instead, as in Kev.
    case branchTooLong(tokens: Int, stateTokens: Int, limit: Int)
    /// A question had no options.
    case noOptions
}

/// One question already reduced to token ids, ready to pack.
public struct KevTokenizedQuestion: Sendable, Equatable {
    /// The instruction text's tokens (without the `<q>` delimiter).
    public let instruction: [Int32]
    /// Each option's tokens (without the `<opt>`/`</opt>` delimiters), in the order the model
    /// should see them.
    public let options: [[Int32]]

    public init(instruction: [Int32], options: [[Int32]]) {
        self.instruction = instruction
        self.options = options
    }
}

/// The packed row: what the backbone consumes and where the head reads. Field names follow Kev's
/// `encode()` return dictionary so the two can be compared directly in tests.
public struct KevEncoding: Sendable, Equatable {
    /// Token ids, `[<state> …state…] + per question [<q> instr <opt> o </opt> … <decide>]`.
    public let ids: [Int32]
    /// Segment per token: `0` for the state, `k` for question `k` (1-based).
    public let segment: [Int]
    /// Position id per token. Positions restart just after the state for every question branch,
    /// so each branch looks to the model like the only continuation of the state.
    public let position: [Int32]
    /// Option index per token within its question: ``KevEncoding/optionNone`` for state and
    /// instruction tokens, `0…K−1` inside option spans, ``KevEncoding/optionDecide`` for `<decide>`.
    public let option: [Int]
    /// Index of each question's `<decide>` token.
    public let decideIndex: [Int]
    /// Per question, the index of each option's `</opt>` token — the pointer head's key positions.
    public let optionCloseIndex: [[Int]]
    /// Whether the row was packed with option isolation (see ``KevSequencePacker/pack(state:questions:optionIsolation:)``).
    public let optionIsolation: Bool
    /// Whether the state was cut to fit ``KevSequencePacker/maxStateTokens``.
    public let stateTruncated: Bool

    /// Marker in ``option`` for tokens outside any option span.
    public static let optionNone = -1
    /// Marker in ``option`` for the `<decide>` token.
    public static let optionDecide = -2

    /// Number of tokens in the row.
    public var count: Int { ids.count }

    /// The block-causal attention rule, as a boolean allow matrix `[query][key]` (`true` = may
    /// attend): `attend(i, j) iff j ≤ i and (seg[j] == 0 or seg[j] == seg[i])`, so a question
    /// sees the state and itself but never a sibling question — Kev's verified question-isolation
    /// property. With option isolation, an option-span token additionally sees only its own span
    /// (plus state and instruction) and `<decide>` sees everything in its question. The diagonal
    /// is always allowed. Backends turn this into whatever additive/boolean mask the model takes.
    public func attentionAllowMatrix() -> [[Bool]] {
        let n = ids.count
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var allow = segment[j] == 0 || segment[j] == segment[i]
                if optionIsolation, allow {
                    let keyIsOption = option[j] >= 0
                    let queryIsDecide = option[i] == Self.optionDecide
                    let sameOption = option[j] == option[i]
                    allow = !keyIsOption || queryIsDecide || sameOption
                }
                rows[i][j] = allow || i == j
            }
        }
        return rows
    }
}

/// Packs a state and its questions into one Kev row — a Swift port of `kev/model.py`'s
/// `encode()`, byte-for-byte on the golden fixture in
/// `Tests/AnglesiteCorePortableTests/Fixtures/Kev/packer-golden.json`.
public struct KevSequencePacker: Sendable {
    /// Kev's training-time row limits (`MAX_STATE`, `MAX_BRANCH`). The model was trained within
    /// these, so serving beyond them trades accuracy for reach; the interaction screen's states
    /// are a few hundred tokens, well inside.
    public static let defaultMaxStateTokens = 384
    public static let defaultMaxBranchTokens = 1024

    public let delimiters: KevDelimiters
    public let maxStateTokens: Int
    public let maxBranchTokens: Int

    public init(
        delimiters: KevDelimiters,
        maxStateTokens: Int = KevSequencePacker.defaultMaxStateTokens,
        maxBranchTokens: Int = KevSequencePacker.defaultMaxBranchTokens
    ) {
        self.delimiters = delimiters
        self.maxStateTokens = max(1, maxStateTokens)
        self.maxBranchTokens = max(1, maxBranchTokens)
    }

    /// Kev's `user_tokens()` escape: any `<|name|>` in caller text becomes `<¦name¦>` (broken bar,
    /// U+00A6) before tokenisation, so caller-supplied text can never produce a delimiter token.
    /// Applied to state, instructions and option text alike.
    public static func escapeSpecials(_ text: String) -> String {
        guard text.contains("<|") else { return text }
        let regex = try! NSRegularExpression(pattern: #"<\|([A-Za-z0-9_]+)\|>"#)
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "<¦$1¦>")
    }

    /// Packs one row.
    ///
    /// - Parameters:
    ///   - state: The state's tokens (already escaped and encoded). Truncated to
    ///     `maxStateTokens − 1` so the `<state>` delimiter fits, as Kev does.
    ///   - questions: The questions in order; each becomes one branch.
    ///   - optionIsolation: Kev's permutation-invariant variant: every option span is its own
    ///     sub-branch, all spans share position ids, and `<decide>` sits one fixed position after
    ///     the longest span. The published kev-0.5b checkpoint was trained *without* it, so the
    ///     default is `false`.
    /// - Returns: The packed row.
    /// - Throws: ``KevPackingError/branchTooLong(tokens:stateTokens:limit:)`` or
    ///   ``KevPackingError/noOptions``.
    public func pack(state: [Int32], questions: [KevTokenizedQuestion], optionIsolation: Bool = false) throws -> KevEncoding {
        let stateTruncated = state.count + 1 > maxStateTokens
        let stateRow: [Int32] = [delimiters.state] + Array(state.prefix(maxStateTokens - 1))
        var ids = stateRow
        var segment = [Int](repeating: 0, count: stateRow.count)
        var position = (0..<stateRow.count).map(Int32.init)
        var option = [Int](repeating: KevEncoding.optionNone, count: stateRow.count)
        var decideIndex: [Int] = []
        var optionCloseIndex: [[Int]] = []

        for (k, question) in questions.enumerated() {
            guard !question.options.isEmpty else { throw KevPackingError.noOptions }
            let instruction: [Int32] = [delimiters.question] + question.instruction
            let spans: [[Int32]] = question.options.map { [delimiters.optionOpen] + $0 + [delimiters.optionClose] }
            let branch: [Int32] = instruction + spans.flatMap { $0 } + [delimiters.decide]
            guard branch.count <= maxBranchTokens - stateRow.count else {
                throw KevPackingError.branchTooLong(tokens: branch.count, stateTokens: stateRow.count, limit: maxBranchTokens)
            }
            let base = ids.count
            let p0 = stateRow.count

            var branchOption = [Int](repeating: KevEncoding.optionNone, count: instruction.count)
            for (j, span) in spans.enumerated() { branchOption += [Int](repeating: j, count: span.count) }
            branchOption.append(KevEncoding.optionDecide)

            var branchPosition: [Int32]
            if optionIsolation {
                let longest = spans.map(\.count).max() ?? 0
                branchPosition = (p0..<(p0 + instruction.count)).map(Int32.init)
                for span in spans {
                    branchPosition += (0..<span.count).map { Int32(p0 + instruction.count + $0) }
                }
                branchPosition.append(Int32(p0 + instruction.count + longest))
            } else {
                branchPosition = (p0..<(p0 + branch.count)).map(Int32.init)
            }

            var ends: [Int] = []
            var cursor = instruction.count
            for span in spans {
                cursor += span.count
                ends.append(cursor - 1)
            }

            ids += branch
            segment += [Int](repeating: k + 1, count: branch.count)
            position += branchPosition
            option += branchOption
            decideIndex.append(base + branch.count - 1)
            optionCloseIndex.append(ends.map { base + $0 })
        }

        return KevEncoding(
            ids: ids, segment: segment, position: position, option: option,
            decideIndex: decideIndex, optionCloseIndex: optionCloseIndex,
            optionIsolation: optionIsolation, stateTruncated: stateTruncated)
    }
}

/// Renders a ``DecisionQuestion`` into the instruction and option strings Kev's API layer
/// (`kev/api.py`'s `to_record`) would build for the equivalent `/v1/systemone` request, so the
/// on-device model sees exactly the text distribution it was trained on.
///
/// The one deliberate mapping: Kev orders a `noul`'s options `[no, yes]` and reads `p(yes)` from
/// index 1, whereas ``DecisionQuestion/noulOptions`` is `[yes, no]`. ``KevQuestionRendering/optionOrder``
/// records the permutation so the scorer can hand back scores in the question's own order.
public struct KevQuestionRendering: Sendable, Equatable {
    /// The instruction text (Kev's `instr`).
    public let instruction: String
    /// The option texts in the order Kev sees them.
    public let options: [String]
    /// `optionOrder[i]` is the index into the ``DecisionQuestion/options`` that Kev's option `i`
    /// corresponds to.
    public let optionOrder: [Int]

    /// Renders `question`. `noul` uses Kev's fixed `no`/`yes` names (no descriptions, since
    /// ``DecisionQuestion/noul(_:)`` carries none); `choice` options are the names themselves;
    /// `score` levels are the level descriptions in ascending order.
    public init(_ question: DecisionQuestion) {
        switch question {
        case .noul(let proposition):
            self.instruction = proposition
            self.options = ["no", "yes"]
            self.optionOrder = [1, 0]
        case .choice(let prompt, let options):
            self.instruction = prompt
            self.options = options
            self.optionOrder = Array(options.indices)
        case .score(let prompt, let levels):
            self.instruction = prompt
            self.options = levels
            self.optionOrder = Array(levels.indices)
        }
    }
}
