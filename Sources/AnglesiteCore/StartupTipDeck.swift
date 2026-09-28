import Foundation

/// Which "tips & tricks" entry the startup screen shows, and in what order. A pure, wrapping
/// cursor over a fixed-size tip list, so the rotation — and the cross-launch cursor that makes
/// each startup open on a tip the owner hasn't just seen — is CI-testable without SwiftUI. The
/// tip text itself lives app-side (`StartupTips`), where the String Catalog can extract it.
/// Design: docs/superpowers/specs/2026-09-28-startup-tips-design.md.
public struct StartupTipDeck: Equatable, Sendable {
    /// How long each tip stays on screen before auto-advancing. Long enough to read a
    /// two-line tip twice at a relaxed pace; startups usually last a few of these.
    public static let dwellSeconds: TimeInterval = 9

    /// Number of tips in the deck; `0` means there is nothing to show.
    public let count: Int
    /// Position of the tip currently showing, always in `0..<count` (or `0` when empty).
    public private(set) var index: Int

    /// - Parameters:
    ///   - count: Number of tips. Negative values are treated as `0`.
    ///   - cursor: Persisted starting position (``AppSettings/startupTipCursor``). Any integer
    ///     is accepted and wrapped into range, so a stale cursor from a build with more tips
    ///     can't index out of bounds.
    public init(count: Int, startingAt cursor: Int) {
        let count = max(0, count)
        self.count = count
        self.index = count == 0 ? 0 : ((cursor % count) + count) % count
    }

    /// `true` when there are no tips to show.
    public var isEmpty: Bool { count == 0 }

    /// Moves to the next tip, wrapping to the first after the last. No-op when empty.
    public mutating func advance() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    /// The cursor to persist once the current tip has been shown, so the next startup opens
    /// on the tip after it.
    public var nextCursor: Int {
        count == 0 ? 0 : (index + 1) % count
    }
}
