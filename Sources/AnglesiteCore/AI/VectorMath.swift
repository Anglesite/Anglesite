import Foundation

/// Small numeric helpers for the semantic index: cosine similarity and a process-stable hash.
public enum VectorMath {
    /// Cosine similarity. Returns 0 when lengths differ or either vector has zero magnitude,
    /// so degenerate inputs rank last instead of crashing.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA.squareRoot() * magB.squareRoot())
    }

    /// FNV-1a 64-bit hash. Stable across process runs (unlike `Hasher`). Callers that need the
    /// raw numeric hash (e.g. `LexicalEmbeddingProvider`'s bucketing) should use this directly
    /// rather than round-tripping through `stableHash`'s hex `String`.
    public static func stableHashValue(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// FNV-1a 64-bit hash as hex. Stable across process runs (unlike `Hasher`), so it is safe
    /// as a cache-invalidation key for embedded text.
    public static func stableHash(_ text: String) -> String {
        String(stableHashValue(text), radix: 16)
    }
}
