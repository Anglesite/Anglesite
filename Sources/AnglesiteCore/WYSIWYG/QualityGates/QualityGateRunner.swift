import Foundation

/// Orchestrates all five checkers (spec §6) after every applied op (design doc §2/§3). Pure and
/// synchronous — no logging, no I/O beyond what the individual gates do — so it's trivial to unit
/// test and so `WYSIWYGCanvasController` (which does have `LogCenter` access, Task 10) decides what
/// to do with a failed category rather than this type reaching into logging itself.
///
/// Isolation is at the *category* level, not per-item within a category (one bad image doesn't get
/// its own try/catch inside `ImageWeightGate`) — this do/catch loop is the only place a checker
/// failure is caught, deliberately not covered by a forced-failure unit test: most CI containers run
/// as root, where POSIX permission bits don't block anything, so a chmod-based test that reliably
/// forces `ImageWeightGate`'s `attributesOfItem` to throw locally would be flaky in CI. The loop
/// itself is simple enough to review by inspection.
public enum QualityGateRunner {
    public struct Result: Sendable {
        public let findings: [Finding]
        public let failedCategories: [FindingCategory]
    }

    private static let gates: [(FindingCategory, (BlockModel, GateContext) throws -> [Finding])] = [
        (.contrast, ContrastGate.analyze),
        (.altText, AltTextGate.analyze),
        (.headingOrder, HeadingOrderGate.analyze),
        (.linkIntegrity, LinkIntegrityGate.analyze),
        (.imageWeight, ImageWeightGate.analyze),
    ]

    public static func analyze(model: BlockModel, context: GateContext) -> Result {
        var findings: [Finding] = []
        var failed: [FindingCategory] = []
        for (category, gate) in gates {
            do {
                findings.append(contentsOf: try gate(model, context))
            } catch {
                failed.append(category)
            }
        }
        return Result(findings: findings, failedCategories: failed)
    }
}
