import Foundation
import AnglesiteCore
import AnglesiteIOS

/// Typed read/write access to one row of an `objectArray` field — the value logic behind the
/// iOS `ObjectArrayEditor`'s per-member bindings, kept binding-free so it tests without SwiftUI.
/// Mirrors the Mac editor's rules: an absent or mismatched value reads as the kind's empty value,
/// and a mid-edit number draft never clobbers a valid stored number.
public enum ObjectRecordFields {
    /// One row's values, keyed by member-field name.
    public typealias Record = [String: TypedContentEditor.FieldValue]

    /// A fresh row with every member field at its kind's default value.
    ///
    /// - Parameter memberFields: The object array's member fields.
    /// - Returns: The empty record.
    public static func emptyRecord(memberFields: [ContentTypeField]) -> Record {
        Dictionary(uniqueKeysWithValues: memberFields.map {
            ($0.name, TypedContentEditor.defaultValue(for: $0.kind))
        })
    }

    /// The text of a string-like member, or `""` when absent or not text.
    public static func text(_ name: String, in record: Record) -> String {
        if case .text(let s)? = record[name] { return s }
        return ""
    }

    /// The flag of a boolean member, or `false` when absent or not a flag.
    public static func flag(_ name: String, in record: Record) -> Bool {
        if case .flag(let b)? = record[name] { return b }
        return false
    }

    /// The date of a date member, or `nil` when absent, cleared, or not a date. (The control
    /// substitutes "now" for `nil`, since a `DatePicker` needs a concrete value to show.)
    public static func date(_ name: String, in record: Record) -> Date? {
        if case .date(let d?)? = record[name] { return d }
        return nil
    }

    /// The display text of a number member: the in-progress draft if one exists (so "3." stays
    /// "3." while typing), else the stored number formatted, else `""`.
    ///
    /// - Parameters:
    ///   - name: The member field.
    ///   - record: The row.
    ///   - draft: The row's mid-edit text for this member, if any.
    /// - Returns: What the text field should show.
    public static func numberText(_ name: String, in record: Record, draft: String?) -> String {
        if let draft { return draft }
        if case .number(let n?)? = record[name] { return ComposerNumberFormat.display(n) }
        return ""
    }

    /// Interprets typed number text: whitespace-only clears the value, a parseable number
    /// stores it, and anything else leaves the stored value untouched (the draft keeps the
    /// text on screen).
    ///
    /// - Parameter raw: The text field's contents.
    /// - Returns: The value to store, or `nil` to leave the record unchanged.
    public static func parsedNumber(from raw: String) -> TypedContentEditor.FieldValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .number(nil) }
        if let parsed = Double(trimmed) { return .number(parsed) }
        return nil
    }
}
