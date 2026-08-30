import Foundation
import Observation
import UniformTypeIdentifiers
import AnglesiteCore

/// The native inspector's model for one selected WYSIWYG block (#1588 Task 6) — the WYSIWYG
/// analog of `TypedEntryEditorModel`'s per-field binding methods (`TypedEntryEditorModel.swift`),
/// but committing per-edit through `Op.setProp` rather than buffering until an explicit Save: the
/// canvas has no Save step, everything applies live (design doc §1).
@MainActor
@Observable
final class WYSIWYGInspectorModel {
    let controller: WYSIWYGCanvasController
    let blockId: BlockId
    private let sourceDirectory: URL?
    private let collection: LicensableCollection?
    private let licensingPolicy: LicensingPolicy

    /// What the license section (#1672) should render for the selected block right now. Stored
    /// (not computed) and refreshed explicitly by `refreshLicenseSection()` — both on `init` and
    /// after `setEmbeddedLicense(_:)` rewrites the file — because a license rewrite never touches
    /// `controller.model` (the block's `src` prop is untouched), so nothing would otherwise tell
    /// `@Observable` to re-render the section.
    private(set) var licenseSectionState: WYSIWYGLicenseSectionState?

    /// `sourceDirectory` is the open site's `Source/` directory (nil when no site is open, or in
    /// tests that don't need the license section); `routePath` is the active preview route,
    /// resolved to a `LicensableCollection` the same way `InsertCommands.insertImage` does.
    /// Both default so every existing 2-arg call site keeps compiling unchanged.
    init(controller: WYSIWYGCanvasController, blockId: BlockId, sourceDirectory: URL? = nil, routePath: String = "/") {
        self.controller = controller
        self.blockId = blockId
        self.sourceDirectory = sourceDirectory
        self.collection = LicensableCollection(routePath: routePath)
        self.licensingPolicy = sourceDirectory.flatMap { try? LicensingStore(sourceDirectory: $0).load() } ?? LicensingPolicy()
        refreshLicenseSection()
    }

    private var node: BlockNode? { controller.model.blocks[blockId] }

    /// The editable props for this block's kind, resolved from the interim palette (Task 5) by
    /// matching `componentName` — real prop schemas arrive with #1222's CEM manifest.
    var descriptors: [WYSIWYGPropDescriptor] {
        guard let node else { return [] }
        return WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == node.componentName }?.props ?? []
    }

    func stringValue(for name: String) -> String {
        guard case .string(let value)? = node?.props[name] else { return "" }
        return value
    }

    func setString(_ value: String, for name: String) {
        Task { await commit(name: name, value: .string(value)) }
    }

    func numberValue(for name: String) -> Double {
        guard case .number(let value)? = node?.props[name] else { return 0 }
        return value
    }

    func setNumber(_ value: Double, for name: String) {
        Task { await commit(name: name, value: .number(value)) }
    }

    func boolValue(for name: String) -> Bool {
        guard case .bool(let value)? = node?.props[name] else { return false }
        return value
    }

    func setBool(_ value: Bool, for name: String) {
        Task { await commit(name: name, value: .bool(value)) }
    }

    private func commit(name: String, value: PropValue) async {
        let previous = node?.props[name] ?? .null
        await controller.submit(.setProp(blockId: blockId, propName: name, value: value, previousValue: previous))
    }

    /// Rewrites the selected block's image file in place with `license` embedded (#1672 resolved
    /// default 4) — atomically, at the resolved `public/` path. Only the file's own metadata
    /// changes; the block's `src` prop, and therefore what the page renders, is untouched, and
    /// `AppSettings.shared.lastUsedFileLicenseSelection` is deliberately not updated (resolved
    /// default 7 — that value is the attach-time picker's memory, not this one-off correction's).
    /// A no-op if the section isn't currently `.editable` or the write fails (defensive; the view
    /// only calls this when it's already showing the editable state).
    func setEmbeddedLicense(_ license: LicenseRef) {
        guard case .editable(_, let fileURL, let type) = licenseSectionState,
              let data = try? Data(contentsOf: fileURL),
              let result = try? LicenseMetadataEmbedder.embed(license, into: data, type: type),
              case .embedded(let newData) = result
        else { return }
        try? newData.write(to: fileURL, options: .atomic)
        refreshLicenseSection()
    }

    private func refreshLicenseSection() {
        licenseSectionState = Self.resolveLicenseSectionState(
            node: node, sourceDirectory: sourceDirectory, collection: collection, licensingPolicy: licensingPolicy)
    }

    private static func resolveLicenseSectionState(
        node: BlockNode?, sourceDirectory: URL?, collection: LicensableCollection?, licensingPolicy: LicensingPolicy
    ) -> WYSIWYGLicenseSectionState? {
        guard let node, node.componentName == "img" else { return nil }
        guard case .string(let src)? = node.props["src"] else { return nil }
        guard !licensingPolicy.suppressesFileEmbedding(for: collection) else { return nil }

        guard let sourceDirectory, let fileURL = WYSIWYGAssetLocator.resolve(src: src, siteDirectory: sourceDirectory) else {
            return .disabled(reason: String(localized: "This image isn't stored in the site, so its license can't be read or changed here."))
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .disabled(reason: String(localized: "This image's file is missing from the site."))
        }
        guard let type = UTType(filenameExtension: fileURL.pathExtension), LicenseMetadataEmbedder.supportedTypes.contains(type) else {
            return .unsupportedFormat
        }
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        return .editable(current: LicenseMetadataEmbedder.readLicense(from: data, type: type), fileURL: fileURL, type: type)
    }
}

/// What the WYSIWYG inspector's license section should render for the selected block (#1672).
/// `nil` from `WYSIWYGInspectorModel.licenseSectionState` means "don't show the section at all"
/// — only an `img` block whose page/collection doesn't suppress file-level licensing gets a
/// non-nil state here; every other block kind, and every non-asserting-collection page, are nil.
enum WYSIWYGLicenseSectionState: Equatable {
    /// `src` isn't a resolvable, existing file under `public/` — a remote URL, a `data:` URL, or
    /// a file that's gone missing. Shown disabled with `reason` as the explanatory label; never
    /// an alert.
    case disabled(reason: String)
    /// The file exists but its format has no metadata slot (`LicenseMetadataEmbedder.supportedTypes`
    /// doesn't include it, e.g. WebP) — shown disabled, stating the format carries no license slot.
    case unsupportedFormat
    /// A real, supported file: `current` is what's embedded today (`nil` = no license embedded),
    /// and choosing a catalog entry rewrites `fileURL` in place via `setEmbeddedLicense(_:)`.
    case editable(current: LicenseRef?, fileURL: URL, type: UTType)
}
