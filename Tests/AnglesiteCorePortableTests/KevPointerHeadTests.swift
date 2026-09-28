// Portable-target test (pure Foundation) so the Linux CI leg executes it. With
// ANGLESITE_KEV_ASSETS set, also loads the real head extracted by scripts/kev/extract-kev-head.py.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("KevPointerHead (#2059)")
struct KevPointerHeadTests {
    static var assetsDirectory: URL? {
        ProcessInfo.processInfo.environment["ANGLESITE_KEV_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// d = 3, dp = 2. Q = [[1,0,0],[0,1,0]] + [0,0]; K = [[0,0,1],[0,1,0]] + [1,0].
    static func tinyHead(temperature: Double = 1) throws -> KevPointerHead {
        try KevPointerHead(
            hiddenSize: 3, pointerSize: 2, temperature: temperature,
            qWeight: [1, 0, 0, 0, 1, 0], qBias: [0, 0],
            kWeight: [0, 0, 1, 0, 1, 0], kBias: [1, 0])
    }

    @Test("logits are the scaled dot product of projected decide and option states, over T")
    func logitsMath() throws {
        // decide = [2, 3, 5] → q = [2, 3]. options: [1,1,1] → k = [1+1, 1] = [2,1]; [0,4,0] → k = [1, 4].
        // dots: 2·2 + 3·1 = 7; 2·1 + 3·4 = 14. scale 1/√2.
        let head = try Self.tinyHead()
        let logits = try head.logits(decideState: [2, 3, 5], optionStates: [[1, 1, 1], [0, 4, 0]])
        #expect(logits.count == 2)
        #expect(abs(logits[0] - 7 / 2.0.squareRoot()) < 1e-9)
        #expect(abs(logits[1] - 14 / 2.0.squareRoot()) < 1e-9)

        let cooled = try Self.tinyHead(temperature: 2)
        let scaled = try cooled.logits(decideState: [2, 3, 5], optionStates: [[1, 1, 1]])
        #expect(abs(scaled[0] - logits[0] / 2) < 1e-9)
    }

    @Test("wrong-length tensors and states are rejected")
    func sizeChecks() throws {
        #expect(throws: KevPointerHead.LoadError.unexpectedSize(expected: 6, got: 5)) {
            _ = try KevPointerHead(hiddenSize: 3, pointerSize: 2, temperature: 1,
                                   qWeight: [1, 0, 0, 0, 1], qBias: [0, 0], kWeight: [0, 0, 1, 0, 1, 0], kBias: [1, 0])
        }
        let head = try Self.tinyHead()
        #expect(throws: KevPointerHead.LoadError.unexpectedSize(expected: 3, got: 2)) {
            _ = try head.logits(decideState: [1, 2], optionStates: [])
        }
        #expect(throws: KevPointerHead.LoadError.unexpectedSize(expected: 3, got: 4)) {
            _ = try head.logits(decideState: [1, 2, 3], optionStates: [[1, 2, 3, 4]])
        }
    }

    @Test("head.bin / head.json round-trip through the file loader")
    func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KevPointerHeadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let floats: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0]
        var data = Data()
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        try data.write(to: dir.appendingPathComponent("head.bin"))
        try Data(#"{"d": 3, "dp": 2, "temperature": 1.47, "layout": ["q.weight", "q.bias", "k.weight", "k.bias"]}"#.utf8)
            .write(to: dir.appendingPathComponent("head.json"))

        let head = try KevPointerHead(metadataURL: dir.appendingPathComponent("head.json"), weightsURL: dir.appendingPathComponent("head.bin"))
        #expect(head.hiddenSize == 3 && head.pointerSize == 2 && head.temperature == 1.47)
        let reference = try Self.tinyHead(temperature: 1.47)
        #expect(try head.logits(decideState: [2, 3, 5], optionStates: [[1, 1, 1], [0, 4, 0]])
                == reference.logits(decideState: [2, 3, 5], optionStates: [[1, 1, 1], [0, 4, 0]]))

        try Data(#"{"d": 3, "dp": 2, "layout": ["k.weight"]}"#.utf8).write(to: dir.appendingPathComponent("head.json"))
        #expect(throws: KevPointerHead.LoadError.malformedMetadata("layout")) {
            _ = try KevPointerHead(metadataURL: dir.appendingPathComponent("head.json"), weightsURL: dir.appendingPathComponent("head.bin"))
        }
    }

    @Test("the real kev-0.5b head loads with d=896, dp=256, T=1.47", .enabled(if: assetsDirectory != nil))
    func realHeadLoads() throws {
        let dir = try #require(Self.assetsDirectory)
        let head = try KevPointerHead(metadataURL: dir.appendingPathComponent("head.json"), weightsURL: dir.appendingPathComponent("head.bin"))
        #expect(head.hiddenSize == 896 && head.pointerSize == 256)
        #expect(abs(head.temperature - 1.47) < 1e-9)
        let logits = try head.logits(decideState: [Float](repeating: 0.01, count: 896),
                                     optionStates: [[Float](repeating: 0.02, count: 896), [Float](repeating: -0.02, count: 896)])
        #expect(logits.count == 2 && logits.allSatisfy(\.isFinite))
    }
}
