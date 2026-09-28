import Foundation

/// The transformer half of a Kev model: runs one packed row and returns the final-layer hidden
/// states at the positions the pointer head reads. Core ML in production
/// (`CoreMLKevBackbone`, Darwin only); a fake in tests. Everything else in ``KevOptionScorer``
/// (tokenising, packing, the head, option reordering) is plain Swift and runs anywhere.
public protocol KevBackbone: Sendable {
    /// Hidden size the backbone produces (must equal the head's ``KevPointerHead/hiddenSize``).
    var hiddenSize: Int { get }

    /// Runs `encoding` and returns one hidden-state vector per entry of `indices`, in that order.
    ///
    /// - Throws: ``DecisionError/unavailable(_:)`` when the model can't be loaded or run.
    func hiddenStates(for encoding: KevEncoding, at indices: [Int]) async throws -> [[Float]]
}

/// The on-disk layout of a Kev model asset directory, as `scripts/kev/convert-kev-coreml.py`
/// writes it. Every file is loaded lazily by the component that needs it, so a missing backbone
/// (the large file) fails at first use with ``DecisionError/unavailable(_:)`` rather than at
/// startup.
public struct KevModelAssets: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `vocab.json` — Qwen2's BPE vocabulary, straight from the checkpoint.
    public var vocabURL: URL { directory.appendingPathComponent("vocab.json") }
    /// `merges.txt` — the BPE merge table.
    public var mergesURL: URL { directory.appendingPathComponent("merges.txt") }
    /// `added_tokens.json` — where ``KevDelimiters`` come from.
    public var addedTokensURL: URL { directory.appendingPathComponent("added_tokens.json") }
    /// `head.json` — pointer-head metadata (`d`, `dp`, `temperature`).
    public var headMetadataURL: URL { directory.appendingPathComponent("head.json") }
    /// `head.bin` — pointer-head weights.
    public var headWeightsURL: URL { directory.appendingPathComponent("head.bin") }
    /// `Kev.mlmodelc` — the compiled Core ML backbone.
    public var backboneURL: URL { directory.appendingPathComponent("Kev.mlmodelc") }

    /// Whether the tokenizer and head files are all present. Doesn't check the backbone: on a
    /// host where Core ML is unavailable, the tokenizer/head half still loads and tests.
    public var hasTokenizerAndHead: Bool { hasTokenizerAndHead(fileManager: .default) }

    /// ``hasTokenizerAndHead`` with an injectable file manager; the single place the required
    /// small-file set is listed, so `KevModelLocator` can't drift from it.
    public func hasTokenizerAndHead(fileManager: FileManager) -> Bool {
        [vocabURL, mergesURL, addedTokensURL, headMetadataURL, headWeightsURL]
            .allSatisfy { fileManager.fileExists(atPath: $0.path) }
    }

    /// Loads the delimiters from `added_tokens.json`.
    public func loadDelimiters() throws -> KevDelimiters {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: addedTokensURL)) as? [String: Any] ?? [:]
        var table: [String: Int32] = [:]
        for (token, value) in raw {
            if let id = (value as? NSNumber)?.int32Value { table[token] = id }
        }
        return try KevDelimiters(addedTokens: table)
    }

    /// Loads the tokenizer from `vocab.json` + `merges.txt`.
    public func loadEncoder() throws -> BytePairEncoder {
        try BytePairEncoder(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    /// Loads the pointer head from `head.json` + `head.bin`.
    public func loadHead() throws -> KevPointerHead {
        try KevPointerHead(metadataURL: headMetadataURL, weightsURL: headWeightsURL)
    }
}

/// The Kev-backed ``OptionScorer``: renders a ``DecisionQuestion`` the way Kev's API layer would,
/// escapes and tokenises the text, packs one row, runs the backbone, applies the pointer head,
/// and hands back one logit per option **in the question's own option order**.
///
/// The head already divides by the checkpoint's calibration temperature, so wrapping this in a
/// ``ScoringDecisionProvider`` with ``TemperatureCalibration/identity`` reproduces Kev's served
/// probabilities; a site-fitted temperature from the screening ledger composes on top.
public struct KevOptionScorer: OptionScorer {
    private let encoder: BytePairEncoder
    private let packer: KevSequencePacker
    private let head: KevPointerHead
    private let backbone: any KevBackbone
    private let optionIsolation: Bool

    /// Assembles a scorer from already-loaded parts.
    ///
    /// - Parameters:
    ///   - encoder: The BPE tokenizer.
    ///   - packer: The row packer (carries the delimiters and row limits).
    ///   - head: The pointer head.
    ///   - backbone: The transformer.
    ///   - optionIsolation: Pack rows with option isolation; must match how the checkpoint was
    ///     trained (kev-0.5b: `false`).
    /// - Throws: ``DecisionError/unavailable(_:)`` when the head and backbone disagree on hidden size.
    public init(encoder: BytePairEncoder, packer: KevSequencePacker, head: KevPointerHead,
                backbone: any KevBackbone, optionIsolation: Bool = false) throws {
        guard head.hiddenSize == backbone.hiddenSize else {
            throw DecisionError.unavailable("head hidden size \(head.hiddenSize) ≠ backbone \(backbone.hiddenSize)")
        }
        self.encoder = encoder
        self.packer = packer
        self.head = head
        self.backbone = backbone
        self.optionIsolation = optionIsolation
    }

    /// Loads tokenizer, delimiters and head from `assets` and pairs them with `backbone`.
    ///
    /// - Parameters:
    ///   - assets: The asset directory.
    ///   - head: An already-loaded head, when the caller needed it earlier (e.g. to size the
    ///     backbone); `nil` loads it from `assets`. Passing it avoids reading `head.bin` twice.
    ///   - backbone: The transformer.
    ///   - optionIsolation: See ``init(encoder:packer:head:backbone:optionIsolation:)``.
    /// - Throws: ``DecisionError/unavailable(_:)`` wrapping whichever file failed to load, so a
    ///   caller that only wants "is the model here?" gets one error type.
    public init(assets: KevModelAssets, head: KevPointerHead? = nil, backbone: any KevBackbone, optionIsolation: Bool = false) throws {
        do {
            let encoder = try assets.loadEncoder()
            let packer = KevSequencePacker(delimiters: try assets.loadDelimiters())
            let head = try head ?? assets.loadHead()
            try self.init(encoder: encoder, packer: packer, head: head, backbone: backbone, optionIsolation: optionIsolation)
        } catch let error as DecisionError {
            throw error
        } catch {
            throw DecisionError.unavailable("Kev assets at \(assets.directory.path): \(error)")
        }
    }

    /// Tokenises caller text the way Kev's `user_tokens()` does: escape delimiter look-alikes,
    /// then BPE-encode. Exposed so tests can build expected rows the same way.
    public func userTokens(_ text: String) -> [Int32] {
        encoder.encode(KevSequencePacker.escapeSpecials(text))
    }

    public func score(state: String, question: DecisionQuestion) async throws -> [Double] {
        let rendering = KevQuestionRendering(question)
        let tokenized = KevTokenizedQuestion(
            instruction: userTokens(rendering.instruction),
            options: rendering.options.map(userTokens))
        let encoding: KevEncoding
        do {
            encoding = try packer.pack(state: userTokens(state), questions: [tokenized], optionIsolation: optionIsolation)
        } catch {
            throw DecisionError.unavailable("Kev row packing failed: \(error)")
        }
        let decide = encoding.decideIndex[0]
        let closes = encoding.optionCloseIndex[0]
        let states = try await backbone.hiddenStates(for: encoding, at: [decide] + closes)
        guard states.count == closes.count + 1 else {
            throw DecisionError.malformedScores(expected: closes.count + 1, got: states.count)
        }
        let kevLogits: [Double]
        do {
            kevLogits = try head.logits(decideState: states[0], optionStates: Array(states.dropFirst()))
        } catch {
            throw DecisionError.unavailable("Kev head failed: \(error)")
        }
        // Kev's option i answers the question's option optionOrder[i]; put each logit back where
        // the caller's option set expects it.
        var ordered = [Double](repeating: 0, count: question.options.count)
        for (kevIndex, questionIndex) in rendering.optionOrder.enumerated() where questionIndex < ordered.count {
            ordered[questionIndex] = kevLogits[kevIndex]
        }
        return ordered
    }
}
