import Foundation

/// Writes a discovered feed URL back into a blogroll entry's own `feedURL:` frontmatter
/// (#1483) — the single-scalar counterpart to `SyndicationFrontmatter.adding(urls:to:)`'s
/// list-splice, reusing the same `Frontmatter` primitives. Never overwrites a value the owner
/// (or a prior discovery pass) already set.
enum BlogrollFeedFrontmatter {
    static func setting(feedURL: String, in contents: String) -> String {
        let usesCRLF = contents.contains("\r\n")
        let normalized = usesCRLF ? contents.replacingOccurrences(of: "\r\n", with: "\n") : contents
        func finish(_ s: String) -> String {
            usesCRLF ? s.replacingOccurrences(of: "\n", with: "\r\n") : s
        }

        var lines = normalized.components(separatedBy: "\n")
        let newLine = "feedURL: \(Frontmatter.doubleQuoted(feedURL))"

        guard let closing = Frontmatter.closingFenceIndex(of: lines) else {
            let block = ["---", newLine, "---"]
            return finish((block + [normalized]).joined(separator: "\n"))
        }

        if let keyIndex = lines[..<closing].firstIndex(where: { Frontmatter.splitKeyValue($0)?.key == "feedURL" }) {
            let existingValue = Frontmatter.splitKeyValue(lines[keyIndex])?.value.trimmingCharacters(in: .whitespaces) ?? ""
            guard existingValue.isEmpty else { return contents }
            lines[keyIndex] = newLine
            return finish(lines.joined(separator: "\n"))
        }

        lines.insert(newLine, at: closing)
        return finish(lines.joined(separator: "\n"))
    }
}
