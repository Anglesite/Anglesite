import Foundation

/// The attach-time license picker's persisted last-used choice (#999) — so a site owner who
/// licenses all their photos the same way sets it once. Deliberately just an on/off flag plus a
/// `LicenseCatalog` id rather than a full `LicenseRef`: this picker offers catalog licenses only
/// (no custom URL entry — see the plan doc's Global Constraints), so a stable catalog id is
/// enough to restore the exact same choice next time, and stays valid even if a catalog entry's
/// display name ever changes.
public struct FileLicenseSelection: Codable, Equatable, Sendable {
    /// Whether the checkbox was on — i.e. whether a license should be embedded at all.
    public var isEnabled: Bool
    /// `LicenseCatalog.Entry.id` of the picked license. Meaningful only when `isEnabled`; kept
    /// even when disabled so re-enabling the checkbox restores the same picker selection.
    public var catalogID: String

    public init(isEnabled: Bool, catalogID: String) {
        self.isEnabled = isEnabled
        self.catalogID = catalogID
    }
}
