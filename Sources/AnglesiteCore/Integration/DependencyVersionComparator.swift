import Foundation

/// Ordering-only comparison between two package.json version-range strings (e.g.
/// `"^6.4.8"`, `"~1.2.3"`, `">=3.9.9"`). Deliberately does not implement full semver
/// range-set matching (whether a range *matches* a version) — only whether one
/// range's leading numeric version is greater than another's, which is all the
/// dependency-sync feature needs (spec §3).
public enum DependencyVersionComparator {
    /// Parses the leading `major.minor.patch` out of a range string, ignoring any
    /// prefix characters (`^`, `~`, `>=`, etc.) and any non-numeric suffix on the
    /// final component (pre-release tags like `-beta.1`). Returns `nil` when the
    /// string has no parseable leading numeric version at all (e.g. `"*"`,
    /// `"workspace:*"`, `"latest"`).
    static func numericComponents(_ range: String) -> [Int]? {
        let trimmed = range.drop { !$0.isNumber }
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            components.append(value)
        }
        return components.isEmpty ? nil : components
    }

    /// Returns `true` when `candidate` is a strictly newer version than `other`,
    /// `false` when strictly older or equal, `nil` when either side can't be
    /// parsed — callers must treat `nil` as "don't offer an update", never guess.
    public static func isNewer(_ candidate: String, than other: String) -> Bool? {
        guard let a = numericComponents(candidate), let b = numericComponents(other) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
