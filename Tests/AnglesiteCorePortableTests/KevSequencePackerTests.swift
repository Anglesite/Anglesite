// Portable-target test (pure Foundation) so the Linux CI leg executes it. The golden fixture is
// a record packed by a line-for-line Python port of kev/model.py's encode() and
// branch_mask_batch() (scripts/kev/gen-packer-golden.py) using the real tokenizer, so this suite
// pins the Swift packer to Kev's row layout exactly.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("KevSequencePacker (#2059)")
struct KevSequencePackerTests {
    struct Golden: Decodable {
        struct Encoding: Decodable {
            let ids: [Int32]
            let seg: [Int]
            let pos: [Int32]
            let opt: [Int]
            let decide_idx: [Int]
            let opt_idx: [[Int]]
            let option_isolation: Bool
            let allow: [String]
        }
        struct Tokens: Decodable {
            struct Question: Decodable { let instr: [Int32]; let options: [[Int32]] }
            let state: [Int32]
            let questions: [Question]
        }
        struct Record: Decodable { let state: String }
        let delimiters: KevDelimiters
        let record: Record
        let encodings: [String: Encoding]
        let tokens: Tokens
    }

    static func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "packer-golden", withExtension: "json", subdirectory: "Fixtures/Kev"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    static func questions(_ golden: Golden) -> [KevTokenizedQuestion] {
        golden.tokens.questions.map { KevTokenizedQuestion(instruction: $0.instr, options: $0.options) }
    }

    static func expectMatches(_ encoding: KevEncoding, _ expected: Golden.Encoding) {
        #expect(encoding.ids == expected.ids)
        #expect(encoding.segment == expected.seg)
        #expect(encoding.position == expected.pos)
        #expect(encoding.option == expected.opt)
        #expect(encoding.decideIndex == expected.decide_idx)
        #expect(encoding.optionCloseIndex == expected.opt_idx)
        #expect(encoding.optionIsolation == expected.option_isolation)
        let allow = encoding.attentionAllowMatrix().map { row in row.map { $0 ? "1" : "0" }.joined() }
        #expect(allow == expected.allow)
    }

    @Test("shared-position packing matches Kev's encode() and mask byte for byte")
    func sharedMatchesGolden() throws {
        let golden = try Self.golden()
        let packer = KevSequencePacker(delimiters: golden.delimiters)
        let encoding = try packer.pack(state: golden.tokens.state, questions: Self.questions(golden))
        Self.expectMatches(encoding, try #require(golden.encodings["shared"]))
        #expect(!encoding.stateTruncated)
    }

    @Test("option-isolation packing matches Kev's encode() and mask byte for byte")
    func isolatedMatchesGolden() throws {
        let golden = try Self.golden()
        let packer = KevSequencePacker(delimiters: golden.delimiters)
        let encoding = try packer.pack(state: golden.tokens.state, questions: Self.questions(golden), optionIsolation: true)
        Self.expectMatches(encoding, try #require(golden.encodings["isolated"]))
    }

    @Test("the delimiters resolve from added_tokens.json by Kev's SPECIAL names, in order")
    func delimitersFromAddedTokens() throws {
        let golden = try Self.golden()
        let table: [String: Int32] = [
            "<|fim_prefix|>": 151659, "<|fim_middle|>": 151660, "<|box_start|>": 151648,
            "<|box_end|>": 151649, "<|fim_suffix|>": 151661, "<|endoftext|>": 151643,
        ]
        #expect(try KevDelimiters(addedTokens: table) == golden.delimiters)
        #expect(throws: KevPackingError.missingDelimiter("<|fim_suffix|>")) {
            _ = try KevDelimiters(addedTokens: table.filter { $0.key != "<|fim_suffix|>" })
        }
    }

    @Test("a question's tokens never see a sibling question in the allow matrix")
    func questionIsolation() throws {
        let golden = try Self.golden()
        let encoding = try KevSequencePacker(delimiters: golden.delimiters)
            .pack(state: golden.tokens.state, questions: Self.questions(golden))
        let allow = encoding.attentionAllowMatrix()
        for i in encoding.segment.indices where encoding.segment[i] == 2 {
            for j in encoding.segment.indices where encoding.segment[j] == 1 {
                #expect(!allow[i][j])
            }
        }
        // …but every token sees the whole state and itself.
        for i in encoding.segment.indices {
            #expect(allow[i][i])
            #expect(allow[i][0])
        }
    }

    @Test("the state is truncated to fit, the branch is not")
    func limits() throws {
        let golden = try Self.golden()
        let short = KevSequencePacker(delimiters: golden.delimiters, maxStateTokens: 4, maxBranchTokens: 64)
        let encoding = try short.pack(state: [1, 2, 3, 4, 5, 6], questions: [.init(instruction: [7], options: [[8], [9]])])
        #expect(encoding.stateTruncated)
        #expect(Array(encoding.ids.prefix(4)) == [golden.delimiters.state, 1, 2, 3])
        // Branch: <q> 7 <opt> 8 </opt> <opt> 9 </opt> <decide> = 9 tokens; state row = 4; 9 > 12 − 4 fails.
        let tight = KevSequencePacker(delimiters: golden.delimiters, maxStateTokens: 4, maxBranchTokens: 12)
        #expect(throws: KevPackingError.branchTooLong(tokens: 9, stateTokens: 4, limit: 12)) {
            _ = try tight.pack(state: [1, 2, 3, 4, 5, 6], questions: [.init(instruction: [7], options: [[8], [9]])])
        }
        #expect(throws: KevPackingError.noOptions) {
            _ = try short.pack(state: [1], questions: [.init(instruction: [7], options: [])])
        }
    }

    @Test("escapeSpecials neutralises delimiter look-alikes exactly like Kev's user_tokens()")
    func escapeSpecials() {
        #expect(KevSequencePacker.escapeSpecials("a <|fim_suffix|> b <|im_start|>") == "a <¦fim_suffix¦> b <¦im_start¦>")
        #expect(KevSequencePacker.escapeSpecials("<|not-a-token|> and <| spaced |>") == "<|not-a-token|> and <| spaced |>")
        #expect(KevSequencePacker.escapeSpecials("plain") == "plain")
    }

    @Test("a noul renders as Kev's [no, yes] with the order map back to [yes, no]")
    func noulRendering() {
        let rendering = KevQuestionRendering(.noul("This is spam."))
        #expect(rendering.instruction == "This is spam.")
        #expect(rendering.options == ["no", "yes"])
        #expect(rendering.optionOrder == [1, 0])
    }

    @Test("choice and score render their options in place")
    func choiceAndScoreRendering() {
        let choice = KevQuestionRendering(.choice(prompt: "Kind?", options: ["ad", "reply", "other"]))
        #expect(choice.options == ["ad", "reply", "other"] && choice.optionOrder == [0, 1, 2])
        let score = KevQuestionRendering(.score(prompt: "Tone?", levels: ["hostile", "neutral", "warm"]))
        #expect(score.options == ["hostile", "neutral", "warm"] && score.optionOrder == [0, 1, 2])
    }
}
