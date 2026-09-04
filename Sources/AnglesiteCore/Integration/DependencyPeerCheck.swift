import Foundation

/// One foreign dependency standing in the way of a held-back bump: the site's own
/// (template-untracked) package and the `peerDependencies` range it declares for the
/// package the template wants to bump.
public struct DependencyPeerBlocker: Sendable, Equatable {
    public let dependentName: String
    public let requiredRange: String

    /// Memberwise initializer — blockers are normally produced by
    /// ``DependencyPeerCheck/partition(updates:foreignPeerRequirements:)``; this exists so
    /// tests (and previews) can construct them directly.
    ///
    /// - Parameters:
    ///   - dependentName: The foreign package declaring the peer requirement.
    ///   - requiredRange: The `peerDependencies` range it declares for the bumped package.
    public init(dependentName: String, requiredRange: String) {
        self.dependentName = dependentName
        self.requiredRange = requiredRange
    }
}

/// A template bump withheld from auto-apply because one or more of the site's own
/// dependencies declare a `peerDependencies` range the offered version falls outside (#1440).
public struct DependencyHeldUpdate: Sendable, Equatable {
    public let offer: DependencyUpdateOffer
    /// The blocking foreign dependencies, sorted by name for stable UI order. Never empty.
    public let blockers: [DependencyPeerBlocker]

    /// Memberwise initializer — held updates are normally produced by
    /// ``DependencyPeerCheck/partition(updates:foreignPeerRequirements:)``; this exists so
    /// tests (and previews) can construct them directly.
    ///
    /// - Parameters:
    ///   - offer: The withheld bump exactly as the template offered it.
    ///   - blockers: The foreign dependencies whose peer ranges exclude it.
    public init(offer: DependencyUpdateOffer, blockers: [DependencyPeerBlocker]) {
        self.offer = offer
        self.blockers = blockers
    }
}

/// Pre-checks template bump offers against the `peerDependencies` ranges of the site's own
/// *foreign* dependencies — packages present in the site's `package.json` that the template
/// doesn't track (#1440). Deliberately not a dependency-graph resolver: only the direct
/// peer ranges those foreign packages declare are consulted, and anything unparseable
/// degrades to "don't hold" (never guess, matching `DependencyVersionComparator`'s
/// contract) — the post-apply install (whose failure `DependencyInstallFailureScanner`
/// surfaces) is the backstop for what this check can't read.
public enum DependencyPeerCheck {
    /// Splits `updates` into offers safe to auto-apply and offers held for the owner
    /// because a foreign dependency's declared peer range excludes them.
    ///
    /// - Parameters:
    ///   - updates: The bump offers `DependencySync.diff` produced.
    ///   - foreignPeerRequirements: Foreign-dependency name → its `peerDependencies` map,
    ///     as returned by ``foreignPeerRequirements(sourceDirectory:untrackedDependencyNames:)``.
    /// - Returns: The offers that passed every peer check (`allowed`) and the ones a
    ///   blocker excludes (`held`), each with its full blocker list.
    public static func partition(
        updates: [DependencyUpdateOffer],
        foreignPeerRequirements: [String: [String: String]]
    ) -> (allowed: [DependencyUpdateOffer], held: [DependencyHeldUpdate]) {
        var allowed: [DependencyUpdateOffer] = []
        var held: [DependencyHeldUpdate] = []
        for offer in updates {
            var blockers: [DependencyPeerBlocker] = []
            for (dependentName, peers) in foreignPeerRequirements.sorted(by: { $0.key < $1.key }) {
                guard let requiredRange = peers[offer.name] else { continue }
                // Only an affirmative "the offered range violates this peer range" holds the
                // offer — `nil` (unparseable either side) must never block a legitimate update.
                if offeredRangeSatisfies(offer.offeredRange, peerRange: requiredRange) == false {
                    blockers.append(DependencyPeerBlocker(dependentName: dependentName, requiredRange: requiredRange))
                }
            }
            if blockers.isEmpty {
                allowed.append(offer)
            } else {
                held.append(DependencyHeldUpdate(offer: offer, blockers: blockers))
            }
        }
        return (allowed: allowed, held: held)
    }

    /// Whether the version the offered range would install at minimum (its floor — e.g.
    /// `^7.1.3` → `7.1.3`) satisfies `peerRange`. Checking the floor, not full range
    /// intersection, is deliberate scope (#1440): the floor is what a fresh
    /// `npm install` of the offered range will actually pick, and full range-set
    /// intersection is the dependency-resolver territory this feature stays out of.
    /// `nil` when either side can't be parsed — callers must treat `nil` as "don't
    /// hold", never guess.
    static func offeredRangeSatisfies(_ offeredRange: String, peerRange: String) -> Bool? {
        // A disjunctive offered range has no single floor worth reasoning about.
        guard !offeredRange.contains("||") else { return nil }
        guard let components = DependencyVersionComparator.numericComponents(offeredRange) else { return nil }
        let floor = padded(components)
        return satisfies(floor, range: peerRange)
    }

    /// Reads the `peerDependencies` maps of the named untracked site dependencies: the
    /// site's `package-lock.json` (v2/v3 `packages` entries) is authoritative when it has
    /// an entry for the package; `node_modules/<name>/package.json` is the fallback.
    /// Missing files or entries just yield nothing for that name — this feeds a hold-back
    /// check that must degrade to "no divergence", never block or throw.
    ///
    /// - Parameters:
    ///   - sourceDirectory: The site's `Source/` directory (where `package-lock.json` and
    ///     `node_modules/` live).
    ///   - untrackedDependencyNames: The site dependencies the template's `package.json`
    ///     doesn't declare — the only packages whose peer ranges are foreign constraints.
    /// - Returns: Foreign-dependency name → its non-empty `peerDependencies` map; names
    ///   with no readable peer requirements are simply absent.
    public static func foreignPeerRequirements(
        sourceDirectory: URL,
        untrackedDependencyNames: Set<String>
    ) -> [String: [String: String]] {
        let lockEntries = lockfilePeerEntries(sourceDirectory: sourceDirectory)
        var result: [String: [String: String]] = [:]
        for name in untrackedDependencyNames {
            let peers: [String: String]
            if let lockPeers = lockEntries?["node_modules/\(name)"] {
                peers = lockPeers  // entry present; an empty map authoritatively means "no peers"
            } else {
                peers = nodeModulesPeerDependencies(sourceDirectory: sourceDirectory, packageName: name) ?? [:]
            }
            if !peers.isEmpty { result[name] = peers }
        }
        return result
    }

    // MARK: - Peer-requirement sources

    /// Every `packages` entry in the lockfile, keyed as written (`node_modules/<name>`),
    /// mapped to its `peerDependencies` (empty when the entry declares none). `nil` when
    /// there is no readable lockfile at all — distinct from "entry absent", so the caller
    /// can fall back per package.
    private static func lockfilePeerEntries(sourceDirectory: URL) -> [String: [String: String]]? {
        let lockURL = sourceDirectory.appendingPathComponent("package-lock.json")
        guard let data = try? Data(contentsOf: lockURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let packages = root["packages"] as? [String: Any]
        else { return nil }
        var entries: [String: [String: String]] = [:]
        for (key, value) in packages {
            guard let entry = value as? [String: Any] else { continue }
            entries[key] = entry["peerDependencies"] as? [String: String] ?? [:]
        }
        return entries
    }

    private static func nodeModulesPeerDependencies(sourceDirectory: URL, packageName: String) -> [String: String]? {
        let pkgURL = sourceDirectory
            .appendingPathComponent("node_modules")
            .appendingPathComponent(packageName)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any]
        else { return nil }
        return root["peerDependencies"] as? [String: String]
    }

    // MARK: - Minimal npm range matching (never guess)

    /// Whether `version` (a padded `[major, minor, patch]`) satisfies the npm range
    /// string. Supports the shapes real `peerDependencies` overwhelmingly use — `^`/`~`,
    /// exact and partial/`x` wildcard versions, `>=`/`>`/`<=`/`<`/`=` comparators,
    /// space-joined conjunctions, `a - b` hyphen ranges, and `||` alternatives. Anything
    /// else is `nil`. Pre-release suffixes are compared by their numeric core only (the
    /// one deliberate imprecision; peer ranges pinning pre-releases are vanishingly rare).
    private static func satisfies(_ version: [Int], range: String) -> Bool? {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        var sawUnparseableGroup = false
        for group in trimmed.components(separatedBy: "||") {
            switch satisfiesGroup(version, group.trimmingCharacters(in: .whitespaces)) {
            case true: return true
            case false: continue
            case nil: sawUnparseableGroup = true
            }
        }
        // Every parseable alternative said no — but an unparseable one might have said
        // yes, so the honest answer there is "don't know".
        return sawUnparseableGroup ? nil : false
    }

    /// One `||` alternative: a space-joined conjunction of comparators, or a hyphen range.
    private static func satisfiesGroup(_ version: [Int], _ group: String) -> Bool? {
        let tokens = group.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return true }
        if let dashIndex = tokens.firstIndex(of: "-") {
            guard tokens.count == 3, dashIndex == 1,
                  let low = parsePartial(tokens[0]), let high = parsePartial(tokens[2])
            else { return nil }
            guard compare(version, low.triple) >= 0 else { return false }
            // `1.2.3 - 2.3` means `>=1.2.3 <2.4.0`; a full `- 2.3.4` upper bound is inclusive.
            return high.count == 3
                ? compare(version, high.triple) <= 0
                : compare(version, upperBoundary(high)) < 0
        }
        var sawUnparseable = false
        for token in tokens {
            switch satisfiesComparator(version, token) {
            case false: return false
            case nil: sawUnparseable = true
            case true: break
            }
        }
        return sawUnparseable ? nil : true
    }

    private static func satisfiesComparator(_ version: [Int], _ token: String) -> Bool? {
        if token.hasPrefix(">=") {
            guard let bound = parsePartial(String(token.dropFirst(2))) else { return nil }
            return compare(version, bound.triple) >= 0
        }
        if token.hasPrefix("<=") {
            guard let bound = parsePartial(String(token.dropFirst(2))), bound.count == 3 else { return nil }
            return compare(version, bound.triple) <= 0
        }
        if token.hasPrefix(">") {
            // npm reads `>1.2` as `>=1.3.0` — partial bounds after `>` are ambiguous
            // enough that guessing isn't worth it.
            guard let bound = parsePartial(String(token.dropFirst())), bound.count == 3 else { return nil }
            return compare(version, bound.triple) > 0
        }
        if token.hasPrefix("<") {
            guard let bound = parsePartial(String(token.dropFirst())) else { return nil }
            return compare(version, bound.triple) < 0
        }
        if token.hasPrefix("^") {
            guard let bound = parsePartial(String(token.dropFirst())) else { return nil }
            guard compare(version, bound.triple) >= 0 else { return false }
            return compare(version, caretUpperBoundary(bound)) < 0
        }
        if token.hasPrefix("~") {
            guard let bound = parsePartial(String(token.dropFirst())) else { return nil }
            guard compare(version, bound.triple) >= 0 else { return false }
            let upper = bound.count >= 2
                ? [bound.triple[0], bound.triple[1] + 1, 0]
                : [bound.triple[0] + 1, 0, 0]
            return compare(version, upper) < 0
        }
        let bare = token.hasPrefix("=") ? String(token.dropFirst()) : token
        guard let bound = parsePartial(bare) else { return nil }
        switch bound.count {
        case 3: return compare(version, bound.triple) == 0
        case 0: return true  // `*` / `x`
        default:  // `6`, `6.1`, `6.x`, `6.1.x`: everything within the specified prefix
            return compare(version, bound.triple) >= 0 && compare(version, upperBoundary(bound)) < 0
        }
    }

    /// `^`'s upper bound: the first version that changes the leftmost non-zero component
    /// (`^6.3.0` → `7.0.0`, `^0.2.3` → `0.3.0`, `^0.0.3` → `0.0.4`).
    private static func caretUpperBoundary(_ bound: (triple: [Int], count: Int)) -> [Int] {
        let t = bound.triple
        if t[0] > 0 || bound.count == 1 { return [t[0] + 1, 0, 0] }  // ^6.3.0 → 7.0.0; ^0 → 1.0.0
        if t[1] > 0 || bound.count == 2 { return [0, t[1] + 1, 0] }  // ^0.2.3 → 0.3.0; ^0.0 → 0.1.0
        return [0, 0, t[2] + 1]  // ^0.0.3 → 0.0.4
    }

    /// The first version past a partial bound's specified prefix (`6` → `7.0.0`, `6.1` → `6.2.0`).
    private static func upperBoundary(_ bound: (triple: [Int], count: Int)) -> [Int] {
        bound.count <= 1
            ? [bound.triple[0] + 1, 0, 0]
            : [bound.triple[0], bound.triple[1] + 1, 0]
    }

    /// Parses one version token into a zero-padded `[major, minor, patch]` plus how many
    /// components were actually written (0 for a pure wildcard). Pre-release/build
    /// suffixes are cut at the first `-`/`+`. `nil` for anything that isn't digits and
    /// `x`/`X`/`*` wildcards.
    private static func parsePartial(_ raw: String) -> (triple: [Int], count: Int)? {
        let core = raw.prefix { $0 != "-" && $0 != "+" }
        guard !core.isEmpty else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var triple = [0, 0, 0]
        var count = 0
        for (index, part) in parts.enumerated() {
            if ["x", "X", "*"].contains(String(part)) { break }  // wildcard ends the specified prefix
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            triple[index] = value
            count = index + 1
        }
        return (triple, count)
    }

    private static func padded(_ components: [Int]) -> [Int] {
        [
            components.count > 0 ? components[0] : 0,
            components.count > 1 ? components[1] : 0,
            components.count > 2 ? components[2] : 0,
        ]
    }

    /// Lexicographic triple comparison: negative when `a < b`, 0 when equal, positive when `a > b`.
    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for index in 0..<3 where a[index] != b[index] {
            return a[index] < b[index] ? -1 : 1
        }
        return 0
    }
}
