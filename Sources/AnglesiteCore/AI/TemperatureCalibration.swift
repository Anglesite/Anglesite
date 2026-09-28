import Foundation

/// A single scalar temperature that rescales a scorer's logits before the restricted softmax
/// (Guo et al. 2017, "temperature scaling") so that ``DecisionAnswer/confidence`` means what a
/// gate needs it to mean: among answers reported at 80%, about 80% are right. Fitted on a held-out
/// set of labelled decisions — for the interaction screen, the owner's own Accept/Reject history —
/// and stored per provider. Raw logits from a readout-head model are typically over-confident
/// (the open Jev reproductions report ECE dropping from ~5% to ~2% after this one-parameter fit),
/// which is why the fit is part of the seam rather than left to each backend.
public struct TemperatureCalibration: Codable, Sendable, Equatable {
    /// One labelled decision: the scorer's raw logits and which option was actually correct.
    public struct Sample: Sendable, Equatable {
        /// Raw option scores, in option order.
        public let logits: [Double]
        /// Index into `logits` of the option that turned out to be right.
        public let correctIndex: Int

        public init(logits: [Double], correctIndex: Int) {
            self.logits = logits
            self.correctIndex = correctIndex
        }
    }

    /// The fitted temperature; always positive.
    public let temperature: Double

    /// Leaves logits untouched (`temperature == 1`) — the state before any fit.
    public static let identity = TemperatureCalibration(temperature: 1)

    /// Wraps an explicit temperature, clamped to a small positive floor.
    public init(temperature: Double) {
        self.temperature = max(temperature, 1e-6)
    }

    /// Fits the temperature that minimises negative log-likelihood of `samples` — a 1-D convex
    /// problem, solved here by golden-section search over `log T ∈ [−4, 4]` (T from ~0.018 to
    /// ~55), which is deterministic, dependency-free and converges in a few dozen evaluations.
    /// Samples whose `correctIndex` is out of range, or whose logits are empty, are skipped.
    ///
    /// - Parameter samples: Labelled decisions. Fewer than ``TemperatureCalibration/minimumSamples`` valid samples returns
    ///   ``TemperatureCalibration/identity``: a temperature fitted on a handful of labels overfits badly enough to make
    ///   the gate *less* trustworthy than no calibration at all.
    /// - Returns: The fitted calibration, or ``TemperatureCalibration/identity`` when there isn't enough data.
    public static func fit(samples: [Sample]) -> TemperatureCalibration {
        let valid = samples.filter { !$0.logits.isEmpty && $0.logits.indices.contains($0.correctIndex) }
        guard valid.count >= minimumSamples else { return .identity }

        func nll(logTemperature: Double) -> Double {
            let t = exp(logTemperature)
            var total = 0.0
            for sample in valid {
                let p = DecisionScoring.softmax(sample.logits, temperature: t)[sample.correctIndex]
                total -= log(max(p, 1e-12))
            }
            return total / Double(valid.count)
        }

        var low = -4.0, high = 4.0
        let phi = (5.0.squareRoot() - 1) / 2
        var c = high - phi * (high - low)
        var d = low + phi * (high - low)
        var fc = nll(logTemperature: c), fd = nll(logTemperature: d)
        for _ in 0..<60 {
            if fc < fd {
                high = d; d = c; fd = fc
                c = high - phi * (high - low); fc = nll(logTemperature: c)
            } else {
                low = c; c = d; fc = fd
                d = low + phi * (high - low); fd = nll(logTemperature: d)
            }
            if high - low < 1e-6 { break }
        }
        return TemperatureCalibration(temperature: exp((low + high) / 2))
    }

    /// The smallest labelled set ``TemperatureCalibration/fit(samples:)`` will fit on. Below this it returns
    /// ``TemperatureCalibration/identity`` (see the `fit` doc for why).
    public static let minimumSamples = 20

    /// Expected calibration error of `samples` under this temperature: the confidence-weighted
    /// gap between reported top-option probability and observed accuracy, bucketed into `bins`
    /// equal-width confidence bins (Naeini et al. 2015). `0` is perfect; the open Jev
    /// reproductions land around `0.02–0.05` after temperature scaling. Reported, never gated on —
    /// it is diagnostic output for the calibration report, not a decision input.
    ///
    /// - Parameters:
    ///   - samples: Labelled decisions, as for ``TemperatureCalibration/fit(samples:)``.
    ///   - bins: Number of confidence buckets; clamped to at least 1.
    /// - Returns: ECE in 0…1, or `0` when there are no valid samples.
    public func expectedCalibrationError(samples: [Sample], bins: Int = 10) -> Double {
        let valid = samples.filter { !$0.logits.isEmpty && $0.logits.indices.contains($0.correctIndex) }
        guard !valid.isEmpty else { return 0 }
        let binCount = max(1, bins)
        var confidenceSum = [Double](repeating: 0, count: binCount)
        var correctCount = [Double](repeating: 0, count: binCount)
        var population = [Double](repeating: 0, count: binCount)
        for sample in valid {
            let answer = DecisionScoring.answer(logits: sample.logits, temperature: temperature)
            let top = answer.probabilities[answer.winnerIndex]
            let bin = min(binCount - 1, Int(top * Double(binCount)))
            confidenceSum[bin] += top
            correctCount[bin] += answer.winnerIndex == sample.correctIndex ? 1 : 0
            population[bin] += 1
        }
        var ece = 0.0
        for bin in 0..<binCount where population[bin] > 0 {
            let accuracy = correctCount[bin] / population[bin]
            let confidence = confidenceSum[bin] / population[bin]
            ece += (population[bin] / Double(valid.count)) * abs(accuracy - confidence)
        }
        return ece
    }
}
