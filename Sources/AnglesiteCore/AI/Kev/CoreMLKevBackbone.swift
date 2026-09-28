import Foundation

// Core ML is Darwin-only. Off-Darwin the file compiles to nothing and `KevOptionScorer` can only
// be paired with a test backbone — the same shape as `NLContextualEmbeddingProvider` (cross-
// platform port design §5).
#if canImport(CoreML)
import CoreML

/// The Core ML export of the Kev backbone (Qwen2.5-0.5B with the LoRA adapter merged), as
/// `scripts/kev/convert-kev-coreml.py` writes it: inputs `input_ids` `[1, L]` int32,
/// `position_ids` `[1, L]` int32 and `attention_mask` `[1, 1, L, L]` additive float
/// (`0` = attend, ``maskedValue`` = blocked); output `hidden_states` `[1, L, d]` float, the
/// final-layer hidden states after the last norm.
///
/// Loaded lazily on first use so a missing or still-downloading asset costs nothing at startup
/// and surfaces as ``DecisionError/unavailable(_:)`` from the first prediction — which
/// `InteractionScreener` turns into "publish unscreened, log once".
public actor CoreMLKevBackbone: KevBackbone {
    /// The additive mask value for a blocked (query, key) pair. Finite so a fully-masked row
    /// can't produce NaN, and comfortably inside float16 range for a half-precision export.
    public static let maskedValue: Float = -1e4

    public nonisolated let hiddenSize: Int
    private let modelURL: URL
    private let configuration: MLModelConfiguration
    private var model: MLModel?

    /// Points at a compiled `Kev.mlmodelc`.
    ///
    /// - Parameters:
    ///   - modelURL: The compiled model directory (see ``KevModelAssets/backboneURL``).
    ///   - hiddenSize: The model's `d`; must match the head (896 for kev-0.5b).
    ///   - computeUnits: Where to run; defaults to letting Core ML choose.
    public init(modelURL: URL, hiddenSize: Int, computeUnits: MLComputeUnits = .all) {
        self.modelURL = modelURL
        self.hiddenSize = hiddenSize
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.configuration = configuration
    }

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw DecisionError.unavailable("Kev backbone not found at \(modelURL.path)")
        }
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            self.model = model
            return model
        } catch {
            throw DecisionError.unavailable("Kev backbone failed to load: \(error)")
        }
    }

    public func hiddenStates(for encoding: KevEncoding, at indices: [Int]) async throws -> [[Float]] {
        let model = try loadedModel()
        let length = encoding.count
        guard indices.allSatisfy({ $0 >= 0 && $0 < length }) else {
            throw DecisionError.malformedScores(expected: length, got: indices.max() ?? -1)
        }
        let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let positionIDs = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        for i in 0..<length {
            inputIDs[i] = NSNumber(value: encoding.ids[i])
            positionIDs[i] = NSNumber(value: encoding.position[i])
        }
        let mask = try MLMultiArray(shape: [1, 1, NSNumber(value: length), NSNumber(value: length)], dataType: .float32)
        let allow = encoding.attentionAllowMatrix()
        let maskPointer = mask.dataPointer.bindMemory(to: Float.self, capacity: length * length)
        for i in 0..<length {
            for j in 0..<length {
                maskPointer[i * length + j] = allow[i][j] ? 0 : Self.maskedValue
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIDs, "position_ids": positionIDs, "attention_mask": mask,
        ])
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: features)
        } catch {
            throw DecisionError.unavailable("Kev backbone prediction failed: \(error)")
        }
        guard let hidden = output.featureValue(for: "hidden_states")?.multiArrayValue,
              hidden.shape.count == 3, hidden.shape[1].intValue == length, hidden.shape[2].intValue == hiddenSize
        else {
            throw DecisionError.unavailable("Kev backbone returned an unexpected hidden_states shape")
        }
        // Copy through the typed accessor rather than assuming a contiguous float32 buffer: the
        // export may be float16 and Core ML is free to hand back strided storage.
        var result: [[Float]] = []
        result.reserveCapacity(indices.count)
        for index in indices {
            var vector = [Float](repeating: 0, count: hiddenSize)
            for k in 0..<hiddenSize {
                vector[k] = hidden[[0, NSNumber(value: index), NSNumber(value: k)]].floatValue
            }
            result.append(vector)
        }
        return result
    }
}
#endif
