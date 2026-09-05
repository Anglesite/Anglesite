// Sources/AnglesiteCore/Social/MicropubComposerProjection.swift
import Foundation

/// The write-direction inverse of `MicropubContentSync`'s mf2-to-field mapping (#869): projects a
/// typed form's `TypedContentEditor.Values` back into the raw mf2 property map a Micropub
/// create/update body carries. The two directions live in the same module on purpose — the iOS
/// composer writes through this projection and the Mac's sync bridge reads through
/// `MicropubContentSync.values(for:properties:updatedAt:slug:)`, so a post edited on the phone
/// resolves to the same field values when it syncs back into the site's git repo.
///
/// Pure value mapping, no I/O — `MicropubClient` transports whatever this produces.
public enum MicropubComposerProjection {
    /// Builds the mf2 property map for `descriptor`'s fields from `values`, stamping
    /// `post-status` from `status`.
    ///
    /// Per-field rules mirror `MicropubContentSync`'s read direction:
    /// - `draft` is skipped — it has no mf2 property of its own; the Post Status extension's
    ///   `post-status` property (stamped here from `status`) is its wire form.
    /// - Fields with no mf2 mapping on the descriptor are skipped — they have no wire form.
    /// - Empty/unset values are omitted rather than sent as blank scalars, matching the read
    ///   direction's omit-don't-placeholder rule for optional fields.
    ///
    /// `mp-slug` is deliberately NOT this projection's concern: it's a create-only command
    /// (re-slugging an existing post on every update would move its URL), so the composer adds it
    /// at create time via ``MicropubClient/deriveSlug(title:explicitSlug:)``.
    ///
    /// - Parameters:
    ///   - descriptor: The content type whose fields are being projected.
    ///   - values: The form's per-field values.
    ///   - status: Stamped as the `post-status` property.
    ///   - visibility: Stamped as the `visibility` property when non-`nil`; **omitted entirely**
    ///     when `nil` (the default), same omit-don't-placeholder rule the optional fields above
    ///     follow. Omission matters on the update path: this map is an update's `replace` map, and
    ///     the deployed Worker's visibility vocabulary is wider than
    ///     ``MicropubPostVisibility`` — ``MicropubPost/visibility`` reads any unrecognized tier
    ///     (`unlisted`, `private`, …) as `public`, so stamping a re-derived value on every save
    ///     would silently widen a post another client restricted. Callers pass a concrete value
    ///     only when it's an actual, deliberate choice (a create, or a picker the owner changed).
    /// - Returns: The mf2 property map for a create body or an update's `replace` map.
    public static func properties(
        for descriptor: ContentTypeDescriptor,
        values: TypedContentEditor.Values,
        status: MicropubPostStatus,
        visibility: MicropubPostVisibility? = nil
    ) -> [String: [JSONValue]] {
        var out: [String: [JSONValue]] = [
            "post-status": [.string(status.rawValue)],
        ]
        if let visibility {
            out["visibility"] = [.string(visibility.rawValue)]
        }
        for field in descriptor.fields where field.name != "draft" {
            guard let property = descriptor.projections.rawMf2Property(forField: field.name),
                  let value = values[field.name],
                  let encoded = mf2Values(for: value, kind: field.kind)
            else { continue }
            out[property] = encoded
        }
        return out
    }

    /// The mf2 property names `descriptor` can round-trip at all — every field with an mf2
    /// mapping except `draft`. The composer uses this to compute an update's `delete` list:
    /// a baseline property in this set whose field value was cleared must be deleted server-side,
    /// while properties outside it (another client's vocabulary) are left untouched.
    ///
    /// - Parameter descriptor: The content type whose mapped properties to list.
    /// - Returns: The raw (unprefixed) mf2 property names, in field declaration order.
    public static func mappedProperties(for descriptor: ContentTypeDescriptor) -> [String] {
        descriptor.fields
            .filter { $0.name != "draft" }
            .compactMap { descriptor.projections.rawMf2Property(forField: $0.name) }
    }

    /// Encodes one field value as its mf2 property values, or `nil` to omit the property
    /// entirely (empty/unset — the read direction's fallbacks or defaults reconstruct it).
    ///
    /// - Parameters:
    ///   - value: The form value to encode.
    ///   - kind: The field's declared kind, which picks the wire shape (e.g. date-only vs.
    ///     full ISO 8601 for `.date` vs. `.datetime`).
    /// - Returns: The property's ordered value list, or `nil` when it should be omitted.
    public static func mf2Values(
        for value: TypedContentEditor.FieldValue,
        kind: ContentTypeField.Kind
    ) -> [JSONValue]? {
        switch value {
        case .text(let s):
            return s.isEmpty ? nil : [.string(s)]
        case .flag(let b):
            // No built-in field maps a bool to an mf2 property today (`draft` rides
            // `post-status` instead); encoded anyway so a future mapped bool isn't silently
            // dropped — `MicropubContentSync.fieldValue`'s `.bool` arm documents the same gap.
            return [.bool(b)]
        case .date(let d):
            guard let d else { return nil }
            let full = MicropubContentSync.isoWithFractionalSeconds.string(from: d)
            return [.string(kind == .date ? String(full.prefix(10)) : full)]
        case .number(let n):
            guard let n else { return nil }
            // Integral values travel as JSON integers — the shape the read direction checks
            // first, and what a rating like 4 (not 4.0) looks like from other Micropub clients.
            if n == n.rounded(), abs(n) < 1e15 { return [.int(Int(n))] }
            return [.double(n)]
        case .list(let items):
            let kept = items.filter { !$0.isEmpty }
            return kept.isEmpty ? nil : kept.map { .string($0) }
        case .records:
            // `objectArray` fields have no wire form here: no built-in collection-stored type
            // declares one (h-resume is a singleton, outside the posting flow), and the read
            // direction doesn't reconstruct nested mf2 objects either. Omitted, not flattened.
            return nil
        }
    }

}
