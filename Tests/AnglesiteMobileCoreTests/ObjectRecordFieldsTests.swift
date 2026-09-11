// Tests for the objectArray row accessors behind the iOS `ObjectArrayEditor` (#1968): the
// empty-value fallbacks, and the number-draft rule that keeps "3." on screen without
// clobbering a stored number.
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteMobileCore

@Suite("ObjectRecordFields")
struct ObjectRecordFieldsTests {
    private static let members: [ContentTypeField] = [
        ContentTypeField("label", .string, required: true),
        ContentTypeField("featured", .bool),
        ContentTypeField("when", .date),
        ContentTypeField("price", .number),
    ]

    @Test("an empty record carries every member at its kind's default")
    func emptyRecordDefaults() {
        let record = ObjectRecordFields.emptyRecord(memberFields: Self.members)
        #expect(record.keys.sorted() == ["featured", "label", "price", "when"])
        #expect(record["label"] == TypedContentEditor.defaultValue(for: .string))
        #expect(record["featured"] == TypedContentEditor.defaultValue(for: .bool))
        #expect(record["price"] == TypedContentEditor.defaultValue(for: .number))
    }

    @Test("text, flag, and date read their typed value or the empty fallback")
    func typedReads() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let record: ObjectRecordFields.Record = ["label": .text("Hi"), "featured": .flag(true), "when": .date(when)]
        #expect(ObjectRecordFields.text("label", in: record) == "Hi")
        #expect(ObjectRecordFields.text("missing", in: record) == "")
        #expect(ObjectRecordFields.text("featured", in: record) == "", "a mismatched kind reads as empty, never crashes")
        #expect(ObjectRecordFields.flag("featured", in: record) == true)
        #expect(ObjectRecordFields.flag("label", in: record) == false)
        #expect(ObjectRecordFields.date("when", in: record) == when)
        #expect(ObjectRecordFields.date("cleared", in: ["cleared": .date(nil)]) == nil)
    }

    @Test("number text prefers the in-progress draft, then the formatted stored value")
    func numberText() {
        let record: ObjectRecordFields.Record = ["price": .number(3), "ratio": .number(0.5), "none": .number(nil)]
        #expect(ObjectRecordFields.numberText("price", in: record, draft: nil) == "3")
        #expect(ObjectRecordFields.numberText("ratio", in: record, draft: nil) == "0.5")
        #expect(ObjectRecordFields.numberText("price", in: record, draft: "3.") == "3.")
        #expect(ObjectRecordFields.numberText("none", in: record, draft: nil) == "")
        #expect(ObjectRecordFields.numberText("absent", in: record, draft: nil) == "")
    }

    @Test("typed number text clears on blank, stores on a valid number, and holds on a partial")
    func parsedNumber() {
        #expect(ObjectRecordFields.parsedNumber(from: "") == .number(nil))
        #expect(ObjectRecordFields.parsedNumber(from: "   ") == .number(nil))
        #expect(ObjectRecordFields.parsedNumber(from: " 4.25 ") == .number(4.25))
        // "3." already parses as 3 (Swift's Double accepts a trailing point) — the draft only
        // keeps the *text* on screen; a genuinely partial entry like "-" leaves the value alone.
        #expect(ObjectRecordFields.parsedNumber(from: "3.") == .number(3))
        #expect(ObjectRecordFields.parsedNumber(from: "-") == nil, "a mid-edit draft must not clobber the stored value")
        #expect(ObjectRecordFields.parsedNumber(from: "abc") == nil)
    }
}
