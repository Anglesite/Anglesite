import Foundation
import Testing
@testable import AnglesiteCore

@Suite("ImageWeightGate")
struct ImageWeightGateTests {
    @Test("flags an image asset over the size threshold")
    func flagsOversizedImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 600 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.map(\.id) == ["img1::imageWeight"])
    }

    @Test("does not flag an image under the threshold")
    func doesNotFlagSmallImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 10 * 1024).write(to: root.appendingPathComponent("photo.jpg"))

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/photo.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }

    @Test("does not flag a src that doesn't resolve to a file on disk")
    func ignoresMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = BlockNode(id: "img1", kind: .astro, componentName: "Image", props: ["src": .string("/does-not-exist.jpg")], slots: [:], sourceSpan: [0, 0])
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: ["img1"], blocks: ["img1": image])
        let context = GateContext(resolvedTokens: [:], internalRoutes: [], assetRoot: root)

        let findings = try ImageWeightGate.analyze(model: model, context: context)

        #expect(findings.isEmpty)
    }
}
