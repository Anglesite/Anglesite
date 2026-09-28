// Portable-target test (pure Foundation) so the Linux CI leg executes it: everything in the
// scorer except the Core ML backbone, driven by a fake backbone. With ANGLESITE_KEV_ASSETS set,
// the real tokenizer, delimiters and head are loaded (still with the fake backbone).
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("KevOptionScorer (#2059)")
struct KevOptionScorerTests {
    static var assetsDirectory: URL? {
        ProcessInfo.processInfo.environment["ANGLESITE_KEV_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Records the row it was given and answers with a hidden state derived from the token at
    /// each requested index, so a test can steer which option the head prefers.
    private actor RecordingBackbone: KevBackbone {
        nonisolated let hiddenSize: Int
        private(set) var encodings: [KevEncoding] = []
        private(set) var requestedIndices: [[Int]] = []
        private let stateFor: @Sendable (Int32, Int) -> [Float]
        var error: DecisionError?

        init(hiddenSize: Int, stateFor: @escaping @Sendable (Int32, Int) -> [Float]) {
            self.hiddenSize = hiddenSize
            self.stateFor = stateFor
        }
        func fail(with error: DecisionError) { self.error = error }
        func hiddenStates(for encoding: KevEncoding, at indices: [Int]) async throws -> [[Float]] {
            if let error { throw error }
            encodings.append(encoding)
            requestedIndices.append(indices)
            return indices.map { stateFor(encoding.ids[$0], $0) }
        }
    }

    /// A no-merge byte tokenizer: every UTF-8 byte is its own token (id = byte value), with the
    /// five Kev delimiters at 300…304. Enough to exercise packing and ordering without the
    /// 151k-entry Qwen tables.
    static func byteEncoder() throws -> BytePairEncoder {
        var vocab: [String: Int32] = [:]
        for (b, symbol) in BytePairEncoder.byteAlphabet.enumerated() { vocab[String(symbol)] = Int32(b) }
        return try BytePairEncoder(vocabulary: vocab, merges: [])
    }
    static let delimiters = KevDelimiters(state: 300, question: 301, optionOpen: 302, optionClose: 303, decide: 304)

    /// d = 2, dp = 1: q = [1, 0], k = [1, 0] → logit = h_opt[0] · h_decide[0].
    static func head(temperature: Double = 1) throws -> KevPointerHead {
        try KevPointerHead(hiddenSize: 2, pointerSize: 1, temperature: temperature,
                           qWeight: [1, 0], qBias: [0], kWeight: [1, 0], kBias: [0])
    }

    @Test("a noul's logits come back in the question's [yes, no] order")
    func noulOrdering() async throws {
        // The fake backbone makes the *second* option span's </opt> (Kev's "yes") score higher:
        // hidden[0] = index, so a later position wins; decide's state is [1, 0].
        let backbone = RecordingBackbone(hiddenSize: 2) { _, index in [Float(index), 0] }
        let scorer = try KevOptionScorer(encoder: Self.byteEncoder(), packer: KevSequencePacker(delimiters: Self.delimiters),
                                         head: Self.head(), backbone: backbone)
        let logits = try await scorer.score(state: "BUY NOW", question: .noul("spam?"))
        #expect(logits.count == 2)
        // Kev order [no, yes] → yes has the higher position → higher logit; returned as [yes, no].
        #expect(logits[0] > logits[1])

        let encoding = try #require(await backbone.encodings.first)
        let indices = try #require(await backbone.requestedIndices.first)
        #expect(indices == [encoding.decideIndex[0]] + encoding.optionCloseIndex[0])
        #expect(encoding.ids.first == Self.delimiters.state)
        #expect(encoding.ids.last == Self.delimiters.decide)
        #expect(encoding.ids.filter { $0 == Self.delimiters.optionClose }.count == 2)
        // "no" and "yes" as bytes appear inside the option spans, in Kev's order.
        let bytes = encoding.ids.map { Int($0) }
        let noAt = try #require(bytes.firstRange(of: [110, 111])?.lowerBound)   // "no"
        let yesAt = try #require(bytes.firstRange(of: [121, 101, 115])?.lowerBound) // "yes"
        #expect(noAt < yesAt)
    }

    @Test("choice logits keep the caller's option order and delimiter look-alikes are escaped")
    func choiceOrderingAndEscaping() async throws {
        let backbone = RecordingBackbone(hiddenSize: 2) { _, index in [Float(index), 0] }
        let scorer = try KevOptionScorer(encoder: Self.byteEncoder(), packer: KevSequencePacker(delimiters: Self.delimiters),
                                         head: Self.head(), backbone: backbone)
        let logits = try await scorer.score(
            state: "text with <|fim_suffix|> inside", question: .choice(prompt: "kind?", options: ["a", "b", "c"]))
        #expect(logits.count == 3)
        #expect(logits[0] < logits[1] && logits[1] < logits[2])
        let encoding = try #require(await backbone.encodings.first)
        // The state row holds no delimiter other than <state> itself: the look-alike was escaped
        // to <¦fim_suffix¦> (byte tokens, since the encoder has no merges).
        let stateRow = encoding.ids.prefix { $0 != Self.delimiters.question }
        #expect(stateRow.dropFirst().allSatisfy { $0 < 256 })
        #expect(scorer.userTokens("<|x|>") == scorer.userTokens("<¦x¦>"))
    }

    @Test("a backbone failure surfaces as DecisionError so the screener fails open")
    func backboneFailurePropagates() async throws {
        let backbone = RecordingBackbone(hiddenSize: 2) { _, _ in [0, 0] }
        await backbone.fail(with: .unavailable("no model"))
        let scorer = try KevOptionScorer(encoder: Self.byteEncoder(), packer: KevSequencePacker(delimiters: Self.delimiters),
                                         head: Self.head(), backbone: backbone)
        await #expect(throws: DecisionError.unavailable("no model")) {
            _ = try await scorer.score(state: "s", question: .noul("q"))
        }
    }

    @Test("a head/backbone hidden-size mismatch is refused at assembly")
    func hiddenSizeMismatch() throws {
        let backbone = RecordingBackbone(hiddenSize: 3) { _, _ in [0, 0, 0] }
        #expect(throws: DecisionError.self) {
            _ = try KevOptionScorer(encoder: Self.byteEncoder(), packer: KevSequencePacker(delimiters: Self.delimiters),
                                    head: Self.head(), backbone: backbone)
        }
    }

    @Test("an oversized branch is reported as unavailable, not a crash")
    func branchOverflow() async throws {
        let backbone = RecordingBackbone(hiddenSize: 2) { _, _ in [0, 0] }
        let packer = KevSequencePacker(delimiters: Self.delimiters, maxStateTokens: 8, maxBranchTokens: 16)
        let scorer = try KevOptionScorer(encoder: Self.byteEncoder(), packer: packer, head: Self.head(), backbone: backbone)
        await #expect(throws: DecisionError.self) {
            _ = try await scorer.score(state: "s", question: .choice(prompt: "a long prompt", options: ["aaaa", "bbbb", "cccc"]))
        }
    }

    @Test("end to end through ScoringDecisionProvider yields a normalised answer")
    func throughProvider() async throws {
        let backbone = RecordingBackbone(hiddenSize: 2) { _, index in [Float(index), 0] }
        let scorer = try KevOptionScorer(encoder: Self.byteEncoder(), packer: KevSequencePacker(delimiters: Self.delimiters),
                                         head: Self.head(), backbone: backbone)
        let provider = ScoringDecisionProvider(scorer: scorer)
        let answers = try await provider.decide(state: "hi", questions: [.noul("spam?")])
        #expect(answers.count == 1)
        #expect(abs(answers[0].probabilities.reduce(0, +) - 1) < 1e-9)
        #expect(answers[0].winnerIndex == 0)  // "yes" (option 0 in our order) won above
    }

    @Test("the real checkpoint's tokenizer, delimiters and head assemble and tokenise the golden state",
          .enabled(if: assetsDirectory != nil))
    func realAssetsAssemble() async throws {
        let assets = KevModelAssets(directory: try #require(Self.assetsDirectory))
        #expect(assets.hasTokenizerAndHead)
        let backbone = RecordingBackbone(hiddenSize: 896) { _, index in
            var v = [Float](repeating: 0, count: 896); v[0] = Float(index) * 0.01; return v
        }
        let scorer = try KevOptionScorer(assets: assets, backbone: backbone)
        let golden = try KevSequencePackerTests.golden()
        let state = golden.record.state
        #expect(scorer.userTokens(state) == golden.tokens.state)
        let logits = try await scorer.score(state: state, question: .noul("This interaction is spam."))
        #expect(logits.count == 2 && logits.allSatisfy(\.isFinite))
        let encoding = try #require(await backbone.encodings.first)
        // Same row as the golden's first question (the fixture's second question is absent here).
        let expected = try #require(golden.encodings["shared"])
        let firstBranchEnd = expected.decide_idx[0]
        #expect(encoding.ids == Array(expected.ids.prefix(firstBranchEnd + 1)))
    }
}
