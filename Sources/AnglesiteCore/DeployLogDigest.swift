import Foundation

/// Reduces a raw deploy log to the deploy-relevant portion before it is summarized on-device.
/// Drops `npm run build` / bundler progress noise, then keeps the tail (where failures surface),
/// capped to fit comfortably inside the on-device model's ~4k-token window.
public enum DeployLogDigest {
    /// Character budget for the digest. The on-device window is ~4,096 tokens (≈16k chars);
    /// 6,000 leaves ample room for the prompt and the guided-generation schema.
    public static let maxCharacters = 6_000

    /// Extract the deploy-relevant text from a raw log. Pure and total.
    public static func extract(from logText: String) -> String {
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !isBuildNoise($0) }
        var digest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Single-pass tail trim: index arithmetic avoids the double O(n) walk of `count` + `suffix`.
        if let start = digest.index(digest.endIndex, offsetBy: -maxCharacters, limitedBy: digest.startIndex) {
            digest = String(digest[start...])
        }
        return digest
    }

    /// Conservative: only drops lines that are unambiguously build/bundler progress, so a
    /// wrangler error line (which never matches these) always survives.
    private static func isBuildNoise(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("npm run build") { return true }
        // npm script echo, e.g. "> astro build" — requires a letter (not digit) right after "> "
        // *and* no "://" anywhere in the line, so wrangler/JSON lines like "> https://…",
        // "> 1.2.3 deployed", or "> {" all survive (the first two would otherwise still match
        // `\w`, which includes digits, since "h" and "1" are both word characters).
        if trimmed.range(of: #"^> [A-Za-z]"#, options: .regularExpression) != nil,
           !trimmed.contains("://") {
            return true
        }
        if trimmed.hasPrefix("✓ ") { return true }                 // Vite "✓ N modules transformed"
        if trimmed.lowercased().hasPrefix("vite v") { return true } // Vite banner
        if trimmed.lowercased().hasPrefix("transforming") { return true }
        return false
    }

    /// Locates the failing command's terminal error — the last contiguous run of lines that
    /// look like a real error (a wrangler "✘ ERROR", an uppercase "ERROR" token, "npm ERR!", or
    /// "Error:"), plus any indented detail lines immediately following it. The backward walk
    /// handles tools like npm that emit several consecutive "npm ERR!" lines rather than one
    /// line with indented continuations. Earlier, unrelated warning noise (e.g. Astro's
    /// informational content-glob hints) never matches, so this reliably isolates the terminal
    /// failure a non-expert summary should be weighted toward (#1855). Returns `nil` when
    /// nothing matches rather than guessing, so callers can omit the highlight.
    public static func terminalError(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let lastIndex = lines.lastIndex(where: isErrorLine) else { return nil }
        var start = lastIndex
        while start > 0, isErrorLine(lines[start - 1]) {
            start -= 1
        }
        var end = lastIndex
        while end + 1 < lines.count {
            let line = lines[end + 1]
            guard let first = line.first, first.isWhitespace,
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            end += 1
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// Matches lines that report an actual failure rather than routine progress or warning
    /// output. Deliberately narrow: an uppercase "ERROR" token, wrangler's "✘" marker, npm's
    /// "npm ERR!" prefix, or a leading "Error:" — never a lowercase "error" appearing inside an
    /// unrelated sentence, which is how informational warnings mention the word.
    private static func isErrorLine(_ line: String) -> Bool {
        if line.contains("✘") { return true }
        if line.contains("npm ERR!") { return true }
        if line.range(of: #"\bERROR\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^\s*Error:"#, options: .regularExpression) != nil { return true }
        return false
    }
}
