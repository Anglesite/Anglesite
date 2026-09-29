import Foundation

/// A byte-level byte-pair-encoding tokenizer of the GPT-2 / Qwen2 family, in plain Foundation, so
/// the app can feed a Core ML decision model (#2059) without linking a third-party tokenizer.
///
/// Pipeline, matching Hugging Face `tokenizers`' `BPE` model with the Qwen2 configuration
/// (`normalizer: NFC`, `Split(regex)` + `ByteLevel` pre-tokenizer, no `ignore_merges`, no byte
/// fallback): NFC-normalise → split on the pre-tokenizer regex → map each piece's UTF-8 bytes to
/// the byte alphabet → merge adjacent symbols by ascending merge rank → look each symbol up in the
/// vocabulary. It does **not** recognise added/special tokens inside the text: callers that
/// package a prompt escape delimiter look-alikes first (``KevSequencePacker/escapeSpecials(_:)``),
/// which is exactly how Kev's own `user_tokens()` keeps caller text from forging a delimiter.
///
/// Verified against the reference implementation by the golden fixture in
/// `Tests/AnglesiteCorePortableTests/Fixtures/Kev/tokenizer-golden.json`.
public struct BytePairEncoder: Sendable {
    /// Failures while loading the vocabulary and merge tables.
    public enum LoadError: Error, Equatable, Sendable {
        /// `vocab.json` wasn't a `{token: id}` object.
        case malformedVocabulary
        /// A `merges.txt` line wasn't `"<left> <right>"`.
        case malformedMerge(String)
        /// A byte-alphabet symbol is missing from the vocabulary, so some input couldn't be
        /// encoded at all.
        case incompleteByteAlphabet(String)
    }

    /// Qwen2's pre-tokenizer split pattern (also GPT-4's `cl100k` shape): contractions, letter
    /// runs with one optional leading non-letter, single digits, punctuation runs, newline runs,
    /// and whitespace.
    public static let qwen2Pattern =
        #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    private let vocabulary: [String: Int32]
    private let mergeRanks: [String: Int]
    private let pattern: NSRegularExpression

    /// Builds an encoder from in-memory tables.
    ///
    /// - Parameters:
    ///   - vocabulary: Token string (in byte-alphabet form) → id, as in `vocab.json`.
    ///   - merges: Merge rules in priority order, each `"<left> <right>"`, as in `merges.txt`
    ///     (comment lines starting with `#` and blank lines are ignored).
    ///   - pattern: The pre-tokenizer regex; defaults to ``qwen2Pattern``.
    /// - Throws: ``LoadError`` for a malformed merge line, an invalid pattern
    ///   (surfaced as the regex error), or a vocabulary missing one of the 256 byte symbols.
    public init(vocabulary: [String: Int32], merges: [String], pattern: String = BytePairEncoder.qwen2Pattern) throws {
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        var rank = 0
        for line in merges {
            let trimmed = line.trimmingCharacters(in: .newlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw LoadError.malformedMerge(trimmed) }
            let key = Self.pairKey(String(parts[0]), String(parts[1]))
            if ranks[key] == nil { ranks[key] = rank }
            rank += 1
        }
        for symbol in Self.byteAlphabet where vocabulary[String(symbol)] == nil {
            throw LoadError.incompleteByteAlphabet(String(symbol))
        }
        self.vocabulary = vocabulary
        self.mergeRanks = ranks
        self.pattern = try NSRegularExpression(pattern: pattern, options: [])
    }

    /// Loads the standard Hugging Face pair of files.
    ///
    /// - Parameters:
    ///   - vocabURL: `vocab.json`.
    ///   - mergesURL: `merges.txt`.
    ///   - pattern: The pre-tokenizer regex; defaults to ``qwen2Pattern``.
    /// - Throws: ``LoadError``, or the underlying file/JSON error.
    public init(vocabURL: URL, mergesURL: URL, pattern: String = BytePairEncoder.qwen2Pattern) throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL))
        guard let object = raw as? [String: Any] else { throw LoadError.malformedVocabulary }
        var vocabulary: [String: Int32] = [:]
        vocabulary.reserveCapacity(object.count)
        for (token, value) in object {
            guard let id = (value as? NSNumber)?.int32Value else { throw LoadError.malformedVocabulary }
            vocabulary[token] = id
        }
        let merges = try String(contentsOf: mergesURL, encoding: .utf8).components(separatedBy: "\n")
        try self.init(vocabulary: vocabulary, merges: merges, pattern: pattern)
    }

    /// The number of entries in the vocabulary.
    public var vocabularySize: Int { vocabulary.count }

    /// Encodes `text` into token ids. Never throws: a symbol absent from the vocabulary is
    /// impossible after a successful init (every byte symbol is present, and merges only produce
    /// symbols the training vocabulary contains), so the lookup failure path is a defensive skip.
    public func encode(_ text: String) -> [Int32] {
        let normalised = text.precomposedStringWithCanonicalMapping
        let ns = normalised as NSString
        var ids: [Int32] = []
        for match in pattern.matches(in: normalised, options: [], range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            var symbols = piece.utf8.map { Self.byteAlphabet[Int($0)] }
            Self.merge(&symbols, ranks: mergeRanks)
            for symbol in symbols {
                if let id = vocabulary[String(symbol)] { ids.append(id) }
            }
        }
        return ids
    }

    // MARK: - BPE core

    /// The GPT-2 `bytes_to_unicode` table: printable Latin-1 bytes map to themselves, the rest to
    /// code points from U+0100 up, so every byte is a single visible scalar and a token string is
    /// a plain `String`. Indexed by byte value.
    static let byteAlphabet: [Substring] = {
        var bytes: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var next = 256
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            scalars.append(next)
            next += 1
        }
        var table = [Substring](repeating: "", count: 256)
        for (b, scalar) in zip(bytes, scalars) {
            table[b] = Substring(String(UnicodeScalar(scalar)!))
        }
        return table
    }()

    /// Key for the merge-rank table; `\u{1}` never occurs in a byte-alphabet symbol.
    private static func pairKey(_ left: String, _ right: String) -> String { left + "\u{1}" + right }

    /// Repeatedly merges the lowest-ranked adjacent pair until no adjacent pair has a merge rule —
    /// the textbook BPE loop, O(n²) per piece, which is fine at the piece lengths the regex
    /// produces (a word, a number, a punctuation run).
    private static func merge(_ symbols: inout [Substring], ranks: [String: Int]) {
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[pairKey(String(symbols[i]), String(symbols[i + 1]))], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { return }
            let left = symbols[bestIndex], right = symbols[bestIndex + 1]
            let joined = Substring(String(left) + String(right))
            var merged: [Substring] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == left, symbols[i + 1] == right {
                    merged.append(joined)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
    }
}
