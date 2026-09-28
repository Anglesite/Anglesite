import Foundation

/// Kev's pointer head, in plain Swift: two affine maps `d → dp` (a query from the `<decide>`
/// hidden state, a key from each option's `</opt>` hidden state), a scaled dot product, and the
/// checkpoint's calibration temperature. `z = (K(h_opts) · Q(h_decide)) / √dp / T`.
///
/// Kept outside the Core ML graph on purpose: the head is ~1.8 MB of float32, the math is a few
/// hundred multiply-adds per option, and having it here means the whole scorer except the
/// backbone is testable on Linux against a fake backbone — and a retrained head can ship without
/// re-exporting the backbone.
public struct KevPointerHead: Sendable {
    /// Failures while loading `head.bin` / `head.json`.
    public enum LoadError: Error, Equatable, Sendable {
        /// `head.json` lacked a field or named a layout this loader doesn't understand.
        case malformedMetadata(String)
        /// `head.bin` isn't exactly `2·(dp·d + dp)` float32 values.
        case unexpectedSize(expected: Int, got: Int)
    }

    /// Hidden size of the backbone (`d`, 896 for Qwen2.5-0.5B).
    public let hiddenSize: Int
    /// Pointer dimension (`dp`, 256).
    public let pointerSize: Int
    /// Calibration temperature applied to the logits (1.47 for kev-0.5b).
    public let temperature: Double

    private let qWeight: [Float]   // [dp][d], row-major
    private let qBias: [Float]     // [dp]
    private let kWeight: [Float]   // [dp][d]
    private let kBias: [Float]     // [dp]

    /// Builds a head from explicit tensors (row-major `[dp][d]` weights).
    ///
    /// - Throws: ``LoadError/unexpectedSize(expected:got:)`` when a tensor has the wrong length.
    public init(hiddenSize: Int, pointerSize: Int, temperature: Double,
                qWeight: [Float], qBias: [Float], kWeight: [Float], kBias: [Float]) throws {
        let expected = pointerSize * hiddenSize
        for (tensor, size) in [(qWeight, expected), (qBias, pointerSize), (kWeight, expected), (kBias, pointerSize)]
        where tensor.count != size {
            throw LoadError.unexpectedSize(expected: size, got: tensor.count)
        }
        self.hiddenSize = hiddenSize
        self.pointerSize = pointerSize
        self.temperature = max(temperature, 1e-6)
        self.qWeight = qWeight
        self.qBias = qBias
        self.kWeight = kWeight
        self.kBias = kBias
    }

    /// Loads the pair written by `scripts/kev/extract-kev-head.py`: `head.json` (`d`, `dp`,
    /// `temperature`, `layout`) and `head.bin` (the four tensors concatenated, little-endian
    /// float32, in `layout` order).
    public init(metadataURL: URL, weightsURL: URL) throws {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any] ?? [:]
        guard let d = (meta["d"] as? NSNumber)?.intValue, let dp = (meta["dp"] as? NSNumber)?.intValue, d > 0, dp > 0 else {
            throw LoadError.malformedMetadata("d/dp")
        }
        let temperature = (meta["temperature"] as? NSNumber)?.doubleValue ?? 1
        guard (meta["layout"] as? [String]) == ["q.weight", "q.bias", "k.weight", "k.bias"] else {
            throw LoadError.malformedMetadata("layout")
        }
        let data = try Data(contentsOf: weightsURL)
        let expectedCount = 2 * (dp * d + dp)
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            throw LoadError.unexpectedSize(expected: expectedCount * MemoryLayout<Float>.size, got: data.count)
        }
        var floats = [Float](repeating: 0, count: expectedCount)
        data.withUnsafeBytes { raw in
            for i in 0..<expectedCount {
                floats[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        var offset = 0
        func take(_ n: Int) -> [Float] { defer { offset += n }; return Array(floats[offset..<(offset + n)]) }
        let qW = take(dp * d), qB = take(dp), kW = take(dp * d), kB = take(dp)
        try self.init(hiddenSize: d, pointerSize: dp, temperature: temperature,
                      qWeight: qW, qBias: qB, kWeight: kW, kBias: kB)
    }

    /// Scores the options: one logit per entry of `optionStates`, already divided by
    /// `temperature`. Feed these to ``DecisionScoring/answer(logits:temperature:)`` with
    /// temperature `1` (or compose a further site-fitted ``TemperatureCalibration`` on top).
    ///
    /// - Parameters:
    ///   - decideState: The `<decide>` token's final hidden state, `hiddenSize` floats.
    ///   - optionStates: Each option's `</opt>` hidden state, `hiddenSize` floats apiece.
    /// - Returns: `optionStates.count` logits.
    /// - Throws: ``LoadError/unexpectedSize(expected:got:)`` when a state has the wrong length.
    public func logits(decideState: [Float], optionStates: [[Float]]) throws -> [Double] {
        guard decideState.count == hiddenSize else { throw LoadError.unexpectedSize(expected: hiddenSize, got: decideState.count) }
        let query = affine(decideState, weight: qWeight, bias: qBias)
        let scale = 1 / Double(pointerSize).squareRoot()
        var out: [Double] = []
        out.reserveCapacity(optionStates.count)
        for state in optionStates {
            guard state.count == hiddenSize else { throw LoadError.unexpectedSize(expected: hiddenSize, got: state.count) }
            let key = affine(state, weight: kWeight, bias: kBias)
            var dot = 0.0
            for i in 0..<pointerSize { dot += Double(key[i]) * Double(query[i]) }
            out.append(dot * scale / temperature)
        }
        return out
    }

    /// `weight · x + bias` for a row-major `[dp][d]` weight.
    private func affine(_ x: [Float], weight: [Float], bias: [Float]) -> [Double] {
        var y = [Double](repeating: 0, count: pointerSize)
        for row in 0..<pointerSize {
            var acc = Double(bias[row])
            let base = row * hiddenSize
            for col in 0..<hiddenSize { acc += Double(weight[base + col]) * Double(x[col]) }
            y[row] = acc
        }
        return y
    }
}
