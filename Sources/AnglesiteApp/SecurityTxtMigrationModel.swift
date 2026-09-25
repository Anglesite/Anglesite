import Foundation
import AnglesiteCore

/// Thin, `Identifiable` model driving the `security.txt` Adopt/Preserve sheet (design doc "UX").
/// Mirrors `DependencyUpdateModel`'s shape (one whole decision, not a per-row list) since at
/// most one `security.txt` file exists per site — and, since #1962, the only site-open decision
/// still put to the owner: every app-owned file is applied without asking. Only ever presented
/// for `SecurityTxtMigrationPlan.needsDecision` — a file the checker could *not* positively
/// classify (a positive match auto-applies via `.silentAdopt` and never reaches this sheet).
@MainActor
final class SecurityTxtMigrationModel: Identifiable {
    nonisolated let id = UUID()
    private let onDecision: (SecurityTxtMigrationApplier.Decision) -> Void

    init(onDecision: @escaping (SecurityTxtMigrationApplier.Decision) -> Void) {
        self.onDecision = onDecision
    }

    func adopt() { onDecision(.adopt) }
    func preserve() { onDecision(.preserve) }
}
