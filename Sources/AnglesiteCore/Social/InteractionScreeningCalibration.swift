import Foundation

/// Per-site temperature calibration for the interaction screen (#2067). Kev-0.5B ships with a
/// temperature fitted on public data; the screening gate thresholds on
/// ``DecisionAnswer/confidence``, so a fit on *this site's* comments — the owner's own rulings,
/// paired with the model's scores by ``InteractionScreeningLedger/calibrationSamples()`` — is what
/// makes "hold below 0.3 confidence" mean anything. The fit composes on top of the checkpoint's
/// (``ScoringDecisionProvider/init(scorer:calibration:)``), and lives at
/// `Config/interaction-screening-calibration.json` beside the ledger: app-owned state, never in
/// the site's git repo (decision D6).
///
/// Reported, never gated: each refit produces a ``FitReport`` for the Debug pane with the fitted
/// temperature and the expected calibration error before and after. No owner-facing number.
public struct InteractionScreeningCalibrationStore: Sendable {
    /// The file name under `Config/`.
    public static let fileName = "interaction-screening-calibration.json"

    private let store: CodableFileStore<TemperatureCalibration>

    /// Points the store at `<configDirectory>/interaction-screening-calibration.json`.
    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.store = .json(fileURL: configDirectory.appendingPathComponent(Self.fileName), fileManager: fileManager)
    }

    /// The persisted fit, or `nil` when none exists or the file is unreadable — a lost or
    /// corrupt calibration only means the checkpoint's own temperature applies until the next
    /// refit rewrites it. (`TemperatureCalibration`'s decoder clamps a non-positive value, so a
    /// readable file always yields a usable temperature.)
    public func load() -> TemperatureCalibration? {
        (try? store.load()) ?? nil
    }

    /// Persists `calibration`, creating `Config/` if needed.
    public func save(_ calibration: TemperatureCalibration) throws {
        try store.save(calibration)
    }

    /// The calibration to apply to this site's provider: the persisted fit, or
    /// ``TemperatureCalibration/identity`` before any fit exists.
    public var current: TemperatureCalibration { load() ?? .identity }

    /// What one refit did, for the Debug pane.
    public struct FitReport: Sendable, Equatable {
        /// How many labelled rulings the fit used.
        public let sampleCount: Int
        /// The calibration in force before this refit (identity when none was persisted).
        public let previous: TemperatureCalibration
        /// The calibration this refit produced and persisted.
        public let fitted: TemperatureCalibration
        /// ``TemperatureCalibration/expectedCalibrationError(samples:bins:)`` under `previous`.
        public let errorBefore: Double
        /// The same under `fitted`.
        public let errorAfter: Double

        public init(sampleCount: Int, previous: TemperatureCalibration, fitted: TemperatureCalibration,
                    errorBefore: Double, errorAfter: Double) {
            self.sampleCount = sampleCount
            self.previous = previous
            self.fitted = fitted
            self.errorBefore = errorBefore
            self.errorAfter = errorAfter
        }

        /// One Debug-pane line: `Screening calibration: T = 1.32 from 24 rulings (was 1.00); ECE 0.112 → 0.041`.
        public var summary: String {
            String(format: "Screening calibration: T = %.2f from %d rulings (was %.2f); ECE %.3f → %.3f",
                   fitted.temperature, sampleCount, previous.temperature, errorBefore, errorAfter)
        }
    }

    /// Refits the site temperature from `ledger`'s labelled rulings and persists it, when there
    /// are at least ``TemperatureCalibration/minimumSamples`` of them; otherwise leaves whatever
    /// is persisted untouched and returns `nil`. Idempotent and cheap (a golden-section search
    /// over at most a few hundred samples), so callers run it at every site open and after every
    /// ruling rather than scheduling anything. A failed write is swallowed: the report still
    /// describes the fit, and the next refit tries the write again.
    ///
    /// - Returns: The report, or `nil` when there wasn't enough data to fit.
    @discardableResult
    public func refit(from ledger: InteractionScreeningLedger) -> FitReport? {
        // Count only what `fit` will use, so a ledger padded with unusable rows can't trigger a
        // "fit" that is really the identity fallback overwriting an earlier real fit.
        let samples = ledger.calibrationSamples().filter { !$0.logits.isEmpty && $0.logits.indices.contains($0.correctIndex) }
        guard samples.count >= TemperatureCalibration.minimumSamples else { return nil }
        let fitted = TemperatureCalibration.fit(samples: samples)
        let previous = current
        try? save(fitted)
        return FitReport(
            sampleCount: samples.count, previous: previous, fitted: fitted,
            errorBefore: previous.expectedCalibrationError(samples: samples),
            errorAfter: fitted.expectedCalibrationError(samples: samples))
    }
}
