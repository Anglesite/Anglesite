import Foundation
import AnglesiteCore

/// `Insert ▸ Image…`'s license-embedding checkbox + picker, held as a plain value (not directly
/// as AppKit control state) so its resolution logic is unit-testable without a live
/// `NSOpenPanel` — mirrors `LicenseGateSheetView.Selection`'s reasoning exactly. Internal (not
/// `private`) so tests can construct and compare it directly.
struct InsertImageLicenseChoice: Equatable {
    /// Whether the checkbox is on — whether a license should be embedded into the picked file
    /// at all.
    var isEnabled: Bool
    /// The `LicenseCatalog.Entry.id` currently selected in the popup, meaningful only when
    /// `isEnabled` (but always a valid id, so re-enabling the checkbox shows a real choice).
    var catalogID: String

    /// The license to embed, or nil when the checkbox is off or the id doesn't match a known
    /// catalog entry (defensive — the picker only ever offers real ids, so this should not
    /// happen in practice).
    func resolvedLicense() -> LicenseRef? {
        guard isEnabled else { return nil }
        return LicenseCatalog.entries.first { $0.id == catalogID }?.ref
    }

    /// The initial picker state when `Insert ▸ Image…` opens: the persisted last-used choice
    /// when one exists, otherwise the page's resolved collection license as the popup's
    /// starting selection — but with the checkbox left **off**, since embedding is a
    /// destructive edit and this is the very first time the picker has been shown. Falls back
    /// to the catalog's first entry when there is no resolved default to seed from at all (an
    /// untouched site, or a page outside every collection with no site-wide default either) —
    /// the popup must always show a real selection.
    static func initial(resolvedDefault: LicenseRef?, lastUsed: FileLicenseSelection?) -> InsertImageLicenseChoice {
        if let lastUsed {
            return InsertImageLicenseChoice(isEnabled: lastUsed.isEnabled, catalogID: lastUsed.catalogID)
        }
        let fallbackID = LicenseCatalog.entry(for: resolvedDefault)?.id ?? LicenseCatalog.entries[0].id
        return InsertImageLicenseChoice(isEnabled: false, catalogID: fallbackID)
    }

    /// The form this choice is persisted as (`AppSettings.lastUsedFileLicenseSelection`).
    var persisted: FileLicenseSelection {
        FileLicenseSelection(isEnabled: isEnabled, catalogID: catalogID)
    }
}
