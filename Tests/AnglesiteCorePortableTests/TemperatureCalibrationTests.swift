// Portable-target test (pure Foundation) so the Linux CI leg executes it — see
// DecisionProviderTests for the rationale.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("TemperatureCalibration")
struct TemperatureCalibrationTests {

    /// Small deterministic LCG so the synthetic data set is identical on every run and platform.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Synthetic labelled decisions: a scorer whose raw logits are over-confident by a factor
    /// `trueTemperature` relative to the distribution the labels are actually drawn from.
    private static func samples(count: Int, trueTemperature: Double, seed: UInt64 = 7) -> [TemperatureCalibration.Sample] {
        var rng = LCG(state: seed)
        return (0..<count).map { _ in
            let logits = [rng.next() * 8 - 4, rng.next() * 8 - 4, rng.next() * 8 - 4]
            let truth = DecisionScoring.softmax(logits, temperature: trueTemperature)
            let u = rng.next()
            var acc = 0.0, correct = truth.count - 1
            for (index, p) in truth.enumerated() {
                acc += p
                if u < acc { correct = index; break }
            }
            return TemperatureCalibration.Sample(logits: logits, correctIndex: correct)
        }
    }

    @Test("fit recovers the temperature the labels were drawn at")
    func fitRecoversTemperature() {
        let calibration = TemperatureCalibration.fit(samples: Self.samples(count: 4000, trueTemperature: 2.5))
        #expect(calibration.temperature > 2.0 && calibration.temperature < 3.1)
    }

    @Test("fit lowers both negative log-likelihood proxies: ECE drops after calibration")
    func fitImprovesCalibrationError() {
        let samples = Self.samples(count: 4000, trueTemperature: 3, seed: 11)
        let before = TemperatureCalibration.identity.expectedCalibrationError(samples: samples)
        let after = TemperatureCalibration.fit(samples: samples).expectedCalibrationError(samples: samples)
        #expect(after < before)
        #expect(after < 0.05)
    }

    @Test("fewer than the minimum samples returns identity rather than overfitting")
    func tooFewSamplesIsIdentity() {
        let few = Self.samples(count: TemperatureCalibration.minimumSamples - 1, trueTemperature: 3)
        #expect(TemperatureCalibration.fit(samples: few) == .identity)
        #expect(TemperatureCalibration.fit(samples: []) == .identity)
    }

    @Test("invalid samples (empty logits, out-of-range label) are skipped, not fatal")
    func invalidSamplesAreSkipped() {
        var samples = Self.samples(count: 200, trueTemperature: 2)
        samples.append(.init(logits: [], correctIndex: 0))
        samples.append(.init(logits: [1, 2], correctIndex: 5))
        let calibration = TemperatureCalibration.fit(samples: samples)
        #expect(calibration.temperature > 1)
        #expect(calibration.expectedCalibrationError(samples: [.init(logits: [], correctIndex: 0)]) == 0)
    }

    @Test("a non-positive temperature is clamped to a positive floor")
    func temperatureIsClamped() {
        #expect(TemperatureCalibration(temperature: 0).temperature > 0)
        #expect(TemperatureCalibration(temperature: -3).temperature > 0)
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let original = TemperatureCalibration(temperature: 1.75)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TemperatureCalibration.self, from: data) == original)
    }
}
