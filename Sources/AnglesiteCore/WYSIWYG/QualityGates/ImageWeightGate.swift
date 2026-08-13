import Foundation

/// Image file-size checks — new (design doc §2/§7). Detection only this slice: a real fix needs an
/// async, MCP-backed re-encode (design doc §3), deferred to a fast-follow. Stats the resolved asset
/// file directly under `GateContext.assetRoot` — no build required.
public enum ImageWeightGate {
    /// Above this, a photo is large enough to visibly slow a phone connection — matches the
    /// "photos this big load slowly on phones" framing in the design doc's example finding text.
    private static let maxBytes = 500 * 1024

    enum GateError: Error {
        /// File exists per `FileManager.fileExists()` but `attributesOfItem()` threw, indicating
        /// permission/stat changes between the two calls or a race condition. This is defensive
        /// programming—the path is asserted-but-untested because no reliable, portable technique
        /// exists to trigger it: chmod-based tests fail when the process runs as root (CI
        /// environments), race conditions are flaky, and alternative approaches (symlinks to
        /// nonexistent targets, file-as-directory tricks) don't reliably reproduce the condition
        /// across macOS versions. The throw site is retained as defensive code but not tested.
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
                // Defensive: file existed per fileExists() but stat failed. Not tested per the
                // GateError.unreadableAsset doc comment (see enum definition above).
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
