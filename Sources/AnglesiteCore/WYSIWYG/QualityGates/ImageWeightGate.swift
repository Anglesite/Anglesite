import Foundation

/// Image file-size checks — new (design doc §2/§7). Detection only this slice: a real fix needs an
/// async, MCP-backed re-encode (design doc §3), deferred to a fast-follow. Stats the resolved asset
/// file directly under `GateContext.assetRoot` — no build required.
public enum ImageWeightGate {
    /// Above this, a photo is large enough to visibly slow a phone connection — matches the
    /// "photos this big load slowly on phones" framing in the design doc's example finding text.
    private static let maxBytes = 500 * 1024

    enum GateError: Error {
        case unreadableAsset(path: String, underlying: Error)
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks {
            guard case .string(let src)? = node.props["src"], src.hasPrefix("/") else { continue }
            let fileURL = context.assetRoot.appendingPathComponent(String(src.dropFirst()))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue } // not a local asset — nothing to stat
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            } catch {
                throw GateError.unreadableAsset(path: fileURL.path, underlying: error)
            }
            guard let size = attributes[.size] as? Int, size > maxBytes else { continue }
            let sizeKB = size / 1024
            findings.append(Finding(
                blockId: node.id, category: .imageWeight, severity: .warning,
                message: "This photo is \(sizeKB) KB — that large will load slowly on phones."))
        }
        return findings
    }
}
