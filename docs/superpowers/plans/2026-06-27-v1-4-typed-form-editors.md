# V-1.4 Per-type SwiftUI form editors — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every typed content object a schema-driven SwiftUI form editor that round-trips to YAML frontmatter without data loss and commits each save to git.

**Architecture:** All round-trip and mapping logic lives in pure, unit-tested `AnglesiteCore` types (`FrontmatterDocument`, `TypedContentEditor`, `ContentTypeResolver`). The `AnglesiteApp` layer is a thin `@Observable` model + a generic SwiftUI `Form` that renders one control per field `Kind`, wired into `SiteWindow`'s existing navigator-selection routing. `businessProfile` (the only `.page`-stored type) gets a concrete home shipped in the template at `src/pages/about.md`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing (`@Test`/`#expect`), `git` via the existing `NativeContentOperations.processGitCommit`.

**Design spec:** [`docs/superpowers/specs/2026-06-27-v1-4-typed-form-editors-design.md`](../specs/2026-06-27-v1-4-typed-form-editors-design.md)

## Global Constraints

- **ES/Apple-only frameworks** — no third-party Swift deps (CLAUDE.md).
- **Toolchain:** Xcode 27+ / Swift 6.4. Tests run via `swift test --package-path .`. Set `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if the default `swift` is the broken CommandLineTools one (see memory).
- **Worktree:** all work happens in `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors` on branch `feat/346-typed-editors`. `cd` there before any git/build op.
- **App-target logic is not CI-testable** (hosted `.app` won't launch on CI runners). So all testable logic lives in `AnglesiteCore`; `AnglesiteApp` model/view code is validated by `swift build` + manual smoke only.
- **Pure Core types are I/O-free** — `FrontmatterDocument`, `TypedContentEditor`, `ContentTypeResolver` take/return values; no `FileManager`, no `Process`.
- **Round-trip safety is mandatory:** an unedited document serializes byte-identically (modulo uniform line-ending normalization); editing one field never alters untouched keys or the body.
- **Swift Testing**, not XCTest, for all new tests (`import Testing`; `@Suite`/`@Test`/`#expect`).

---

## File Structure

New (AnglesiteCore — pure, tested):
- `Sources/AnglesiteCore/FrontmatterDocument.swift` — read/write frontmatter+body doc with per-key verbatim preservation.
- `Sources/AnglesiteCore/TypedContentEditor.swift` — descriptor-aware bridge: file ⟷ typed field values; per-`Kind` parse/format; markdown field ⟷ body.
- `Sources/AnglesiteCore/ContentTypeResolver.swift` — project-relative path → `ContentTypeDescriptor?`.

New (AnglesiteApp — thin, build-validated):
- `Sources/AnglesiteApp/TypedEntryEditorModel.swift` — `@MainActor @Observable` buffer over `TypedContentEditor` + `FileDocumentIO` + git commit.
- `Sources/AnglesiteApp/TypedEntryEditorView.swift` — generic `Form` rendering controls per `Kind`.

New (template):
- `Resources/Template/src/pages/about.md` — `businessProfile` singleton page.

New (tests):
- `Tests/AnglesiteCoreTests/FrontmatterDocumentTests.swift`
- `Tests/AnglesiteCoreTests/TypedContentEditorTests.swift`
- `Tests/AnglesiteCoreTests/ContentTypeResolverTests.swift`

Modified:
- `Sources/AnglesiteApp/SiteWindow.swift` — add `.typed` editor case + resolution branch in `applyNavigatorSelection` and `mainPaneContent`.

---

## Task 1: `FrontmatterDocument` — round-trip-safe frontmatter+body model (Core)

**Files:**
- Create: `Sources/AnglesiteCore/FrontmatterDocument.swift`
- Modify: `Sources/AnglesiteCore/Frontmatter.swift` — promote the shared YAML scalar/array helpers from `private` to `internal` (`splitKeyValue`, `blockArrayItem`, `parseScalarOrArray`, `unquote`, `decodeDoubleQuoted`) so `FrontmatterDocument` reuses them instead of duplicating. Leave `frontmatterBlock`/`frontmatterPattern` and `parse` untouched.
- Test: `Tests/AnglesiteCoreTests/FrontmatterDocumentTests.swift`
- Test (regression): `Tests/AnglesiteCoreTests/FrontmatterTests.swift` must still pass unchanged.

**Interfaces:**
- Reuses (existing): `FrontmatterValue` (`Sources/AnglesiteCore/Frontmatter.swift`) — `enum FrontmatterValue { case string(String); case bool(Bool); case array([String]) }`. `FrontmatterDocument` does **not** define its own value enum; it stores and returns `FrontmatterValue`.
- Produces:
  - `public struct FrontmatterDocument: Equatable, Sendable`
  - `public static func parse(_ source: String) -> FrontmatterDocument`
  - `public func value(for key: String) -> FrontmatterValue?`
  - `public mutating func set(_ value: FrontmatterValue, for key: String)` — updates an existing key in place (marking it for re-render) or appends a new key at the end.
  - `public var body: String { get set }` — text after the closing `---` fence, verbatim; settable.
  - `public func serialized() -> String`
  - `public var keys: [String]` — frontmatter keys in source order (excludes synthetic raw segments).

- [ ] **Step 1: Write failing tests**

```swift
// Tests/AnglesiteCoreTests/FrontmatterDocumentTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("FrontmatterDocument")
struct FrontmatterDocumentTests {

    @Test("unedited round-trip is the identity")
    func identity() {
        let src = """
        ---
        title: "Hello"
        draft: false
        tags:
          - a
          - b
        ---

        Body text here.
        """ + "\n"
        #expect(FrontmatterDocument.parse(src).serialized() == src)
    }

    @Test("reads scalar, bool, and array values")
    func reads() {
        let doc = FrontmatterDocument.parse("---\ntitle: \"Hi\"\ndraft: true\ntags: [x, y]\n---\nB\n")
        #expect(doc.value(for: "title") == .string("Hi"))
        #expect(doc.value(for: "draft") == .bool(true))
        #expect(doc.value(for: "tags") == .array(["x", "y"]))
        #expect(doc.value(for: "missing") == nil)
    }

    @Test("editing one field leaves untouched keys and body verbatim")
    func editPreserves() {
        let src = "---\ntitle: \"Old\"\nweirdKey: keep-me-exactly\ndraft: false\n---\n\nBody.\n"
        var doc = FrontmatterDocument.parse(src)
        doc.set(.string("New"), for: "title")
        let out = doc.serialized()
        #expect(out.contains("title: \"New\""))
        #expect(out.contains("weirdKey: keep-me-exactly"))   // unknown key preserved verbatim
        #expect(out.contains("draft: false"))
        #expect(out.hasSuffix("\n\nBody.\n"))                // body verbatim
    }

    @Test("setting a new key appends it")
    func appendsNewKey() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"T\"\n---\nB\n")
        doc.set(.string("noreply@x.io"), for: "email")
        #expect(doc.serialized().contains("email: \"noreply@x.io\""))
        #expect(doc.value(for: "email") == .string("noreply@x.io"))
    }

    @Test("no-frontmatter source is all body")
    func noFrontmatter() {
        let doc = FrontmatterDocument.parse("# Heading\n\nbody\n")
        #expect(doc.keys.isEmpty)
        #expect(doc.body == "# Heading\n\nbody\n")
        #expect(doc.serialized() == "# Heading\n\nbody\n")
    }

    @Test("editing the body leaves frontmatter verbatim")
    func editBody() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"T\"\n---\n\nold body\n")
        doc.body = "\nnew body\n"
        let out = doc.serialized()
        #expect(out.contains("title: \"T\""))
        #expect(out.hasSuffix("\nnew body\n"))
    }

    @Test("array set renders block form and round-trips")
    func arraySet() {
        var doc = FrontmatterDocument.parse("---\nhours: []\n---\n")
        doc.set(.array(["Mon 9-5", "Tue 9-5"]), for: "hours")
        let out = doc.serialized()
        let reparsed = FrontmatterDocument.parse(out)
        #expect(reparsed.value(for: "hours") == .array(["Mon 9-5", "Tue 9-5"]))
    }

    @Test("comments and blank lines inside frontmatter survive an unedited round-trip")
    func commentsSurvive() {
        let src = "---\ntitle: \"T\"\n# a comment\n\ndraft: false\n---\nB\n"
        #expect(FrontmatterDocument.parse(src).serialized() == src)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift test --package-path . --filter FrontmatterDocument 2>&1 | tail -20`
Expected: FAIL — `cannot find 'FrontmatterDocument' in scope`.

- [ ] **Step 3: Implement `FrontmatterDocument`**

First, in `Sources/AnglesiteCore/Frontmatter.swift`, promote the shared helpers from `private static func` to `internal static func` (drop the `private` keyword) on exactly these five: `splitKeyValue`, `blockArrayItem`, `parseScalarOrArray`, `unquote`, `decodeDoubleQuoted`. Add a one-line doc note on `parseScalarOrArray` that `FrontmatterDocument` also consumes it. Leave `parse`, `frontmatterBlock`, and `frontmatterPattern` exactly as they are. The existing `FrontmatterValue` enum (`case string`/`bool`/`array`) is reused as-is — do **not** add a new value enum.

Then create `FrontmatterDocument`:

```swift
// Sources/AnglesiteCore/FrontmatterDocument.swift
import Foundation

/// A read/write model of a content file's YAML frontmatter + body.
///
/// Unlike `Frontmatter.parse` (read-only, drops unknown keys, no serialization), this preserves
/// **every** source segment — known keys, unknown keys, comments, and blank lines — in order, each
/// with its verbatim source text. A key is re-rendered only when it is `set`. Consequences the
/// editor relies on:
///
/// - An unedited `parse(...).serialized()` is the identity (modulo uniform line-ending
///   normalization for mixed endings).
/// - Editing one field never disturbs untouched keys or the body.
/// - Form-only editing can never silently drop a hand-authored key or body content.
///
/// Scalar/array parsing reuses `Frontmatter`'s internal helpers, and values are the existing
/// `FrontmatterValue`. Pure value type, no I/O.
public struct FrontmatterDocument: Equatable, Sendable {
    /// One ordered segment of the frontmatter block. A `key` segment is editable; a raw segment
    /// (comment / blank / stray line) is opaque and always serialized verbatim.
    private struct Segment: Equatable {
        var key: String?               // nil ⟹ raw passthrough segment
        var value: FrontmatterValue?   // logical value for key segments
        var verbatim: [String]?        // original source lines; nil once a key segment is mutated
    }

    private var segments: [Segment]
    /// Index into `segments` by key, for O(1) get/set. Only key segments are listed.
    private var indexByKey: [String: Int]
    /// Text after the closing `---` fence, verbatim (internally newline = "\n").
    public var body: String
    private let newline: String
    private let hadFrontmatter: Bool

    public var keys: [String] { segments.compactMap(\.key) }

    public func value(for key: String) -> FrontmatterValue? {
        guard let i = indexByKey[key] else { return nil }
        return segments[i].value
    }

    public mutating func set(_ value: FrontmatterValue, for key: String) {
        if let i = indexByKey[key] {
            segments[i].value = value
            segments[i].verbatim = nil   // force re-render
        } else {
            indexByKey[key] = segments.count
            segments.append(Segment(key: key, value: value, verbatim: nil))
        }
    }

    public func serialized() -> String {
        guard hadFrontmatter else { return body.replacingOccurrences(of: "\n", with: newline) }
        var lines: [String] = ["---"]
        for seg in segments {
            if let verbatim = seg.verbatim {
                lines.append(contentsOf: verbatim)
            } else if let key = seg.key, let value = seg.value {
                lines.append(Self.render(key: key, value: value))
            }
        }
        lines.append("---")
        var out = lines.joined(separator: "\n")
        if !body.isEmpty || hadFrontmatter { out += "\n" + body }
        return out.replacingOccurrences(of: "\n", with: newline)
    }

    // MARK: Parse

    public static func parse(_ source: String) -> FrontmatterDocument {
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")

        guard normalized.hasPrefix("---\n") else {
            return FrontmatterDocument(segments: [], indexByKey: [:], body: normalized,
                                       newline: newline, hadFrontmatter: false)
        }
        let all = normalized.components(separatedBy: "\n")
        // all[0] == "---"; find the closing fence.
        var close = -1
        var i = 1
        while i < all.count { if all[i] == "---" { close = i; break }; i += 1 }
        guard close >= 0 else {
            return FrontmatterDocument(segments: [], indexByKey: [:], body: normalized,
                                       newline: newline, hadFrontmatter: false)
        }
        let block = Array(all[1..<close])
        // body = everything after the closing fence, rejoined (the leading separator after `---`
        // is represented by the first element being "").
        let body = Array(all[(close + 1)...]).joined(separator: "\n")

        var segments: [Segment] = []
        var indexByKey: [String: Int] = [:]
        var j = 0
        while j < block.count {
            let line = block[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Comment / blank / stray-indent → raw passthrough.
            let indented = (line.first == " " || line.first == "\t")
            if trimmed.isEmpty || trimmed.hasPrefix("#") || indented {
                segments.append(Segment(key: nil, value: nil, verbatim: [line]))
                j += 1
                continue
            }
            guard let (key, rawValue) = Frontmatter.splitKeyValue(line) else {
                segments.append(Segment(key: nil, value: nil, verbatim: [line]))
                j += 1
                continue
            }

            var verbatim = [line]
            let value: FrontmatterValue
            if rawValue.isEmpty {
                // Possible block array on following `- item` lines.
                var items: [String] = []
                var k = j + 1
                while k < block.count, let item = Frontmatter.blockArrayItem(block[k]) {
                    items.append(Frontmatter.unquote(item))
                    verbatim.append(block[k])
                    k += 1
                }
                value = items.isEmpty ? .string("") : .array(items)
                j = k
            } else {
                value = Frontmatter.parseScalarOrArray(rawValue)
                j += 1
            }
            indexByKey[key] = segments.count
            segments.append(Segment(key: key, value: value, verbatim: verbatim))
        }
        return FrontmatterDocument(segments: segments, indexByKey: indexByKey, body: body,
                                   newline: newline, hadFrontmatter: true)
    }

    // MARK: Render (mirrors ContentScaffold: double-quoted scalars, `[]` empty arrays, block lists)

    private static func render(key: String, value: FrontmatterValue) -> String {
        switch value {
        case .string(let s):
            return "\(key): \"\(escape(s))\""
        case .bool(let b):
            return "\(key): \(b)"
        case .array(let items):
            if items.isEmpty { return "\(key): []" }
            return ([ "\(key):" ] + items.map { "  - \"\(escape($0))\"" }).joined(separator: "\n")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

Note for the implementer: `Frontmatter.splitKeyValue` returns `(key: String, value: String)?` with the value already trimmed — use it directly. `Frontmatter.parseScalarOrArray`, `.blockArrayItem`, and `.unquote` are the same helpers `Frontmatter.parse` uses, so block-array and quoting semantics stay identical across both types.

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --package-path . --filter FrontmatterDocument 2>&1 | tail -20`
Expected: PASS (8 tests). If `identity`/`commentsSurvive` fail on a trailing-newline mismatch, check the `body` rejoin handles the final `""` element — fix the off-by-one in `serialized()`'s body concatenation before moving on.

Also confirm the existing `Frontmatter` suite still passes after promoting its helpers to `internal`:
Run: `swift test --package-path . --filter Frontmatter 2>&1 | tail -20`
Expected: both `Frontmatter` and `FrontmatterDocument` suites PASS (no regression).

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteCore/Frontmatter.swift Sources/AnglesiteCore/FrontmatterDocument.swift Tests/AnglesiteCoreTests/FrontmatterDocumentTests.swift
git commit -m "$(printf 'feat(#346): FrontmatterDocument round-trip model reusing Frontmatter helpers\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: `TypedContentEditor` — descriptor ⟷ typed field values (Core)

**Files:**
- Create: `Sources/AnglesiteCore/TypedContentEditor.swift`
- Test: `Tests/AnglesiteCoreTests/TypedContentEditorTests.swift`

**Interfaces:**
- Consumes: `FrontmatterDocument` (Task 1), `ContentTypeDescriptor`/`ContentTypeField.Kind` (existing).
- Produces:
  - `public enum TypedContentEditor.FieldValue: Equatable, Sendable { case text(String); case flag(Bool); case date(Date?); case number(Double?); case list([String]) }`
  - `public struct TypedContentEditor.Values: Equatable, Sendable` with `public subscript(_ name: String) -> FieldValue?` and `public init(_ dict: [String: FieldValue])`.
  - `public static func read(_ contents: String, descriptor: ContentTypeDescriptor) -> Values` — every field in `descriptor.fields` gets a value (empty default if absent). The single `markdown` field (if any) is read from the document **body**; all others from frontmatter.
  - `public static func write(_ values: Values, into contents: String, descriptor: ContentTypeDescriptor) -> String` — applies only the fields whose value differs from what `contents` currently holds, so untouched fields stay verbatim (Task 1 guarantee). The markdown field writes to the body.
  - `public static func defaultValue(for kind: ContentTypeField.Kind) -> FieldValue`

Mapping `Kind` → `FieldValue`: `string`/`text`/`url`/`image`/`markdown` → `.text`; `bool` → `.flag`; `date`/`datetime` → `.date`; `number` → `.number`; `stringArray`/`imageArray` → `.list`.

Date formatting (mirror `ContentScaffold.renderEntry`): `datetime` → ISO8601 `[.withInternetDateTime, .withFractionalSeconds]`; `date` → first 10 chars (`yyyy-MM-dd`).

- [ ] **Step 1: Write failing tests**

```swift
// Tests/AnglesiteCoreTests/TypedContentEditorTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("TypedContentEditor")
struct TypedContentEditorTests {
    private var note: ContentTypeDescriptor { ContentTypeRegistry().descriptor(id: "note")! }
    private var event: ContentTypeDescriptor { ContentTypeRegistry().descriptor(id: "event")! }
    private var reply: ContentTypeDescriptor { ContentTypeRegistry().descriptor(id: "reply")! }

    @Test("reads markdown field from body and scalars from frontmatter")
    func reads() {
        let src = "---\npublishDate: 2026-01-02T03:04:05.000Z\ntags: [a, b]\n---\n\nHello body.\n"
        let v = TypedContentEditor.read(src, descriptor: note)
        #expect(v["body"] == .text("\nHello body.\n"))           // markdown ⟷ body
        #expect(v["tags"] == .list(["a", "b"]))
        if case .date(let d?) = v["publishDate"] { #expect(d.timeIntervalSince1970 > 0) } else { Issue.record("no date") }
    }

    @Test("missing fields get empty defaults")
    func defaults() {
        let v = TypedContentEditor.read("---\n---\n", descriptor: reply)
        #expect(v["inReplyTo"] == .text(""))
        #expect(v["body"] == .text(""))
    }

    @Test("write applies only changed fields, leaving others verbatim")
    func writeChangedOnly() {
        let src = "---\ninReplyTo: \"https://a.example/x\"\npublishDate: 2026-01-02T03:04:05.000Z\n---\n\nold.\n"
        var v = TypedContentEditor.read(src, descriptor: reply)
        v = TypedContentEditor.Values([
            "inReplyTo": .text("https://b.example/y"),      // changed
            "publishDate": v["publishDate"]!,               // unchanged
            "body": v["body"]!                              // unchanged
        ])
        let out = TypedContentEditor.write(v, into: src, descriptor: reply)
        #expect(out.contains("inReplyTo: \"https://b.example/y\""))
        #expect(out.contains("publishDate: 2026-01-02T03:04:05.000Z"))  // verbatim, not reformatted
        #expect(out.hasSuffix("\nold.\n"))                              // body verbatim
    }

    @Test("write updates the markdown body")
    func writeBody() {
        let src = "---\npublishDate: 2026-01-02T03:04:05.000Z\n---\n\nold.\n"
        var v = TypedContentEditor.read(src, descriptor: note)
        v = TypedContentEditor.Values(["publishDate": v["publishDate"]!, "tags": v["tags"] ?? .list([]),
                                       "body": .text("\nnew body.\n")])
        let out = TypedContentEditor.write(v, into: src, descriptor: note)
        #expect(out.hasSuffix("\nnew body.\n"))
    }

    @Test("write round-trips a list field into block YAML")
    func writeList() {
        let profile = ContentTypeRegistry().descriptor(id: "businessProfile")!
        let src = "---\ntype: businessProfile\nname: \"Acme\"\nhours: []\n---\n"
        var v = TypedContentEditor.read(src, descriptor: profile)
        var dict = [String: TypedContentEditor.FieldValue]()
        for f in profile.fields { dict[f.name] = v[f.name] }
        dict["hours"] = .list(["Mon 9-5", "Sat closed"])
        let out = TypedContentEditor.write(TypedContentEditor.Values(dict), into: src, descriptor: profile)
        #expect(TypedContentEditor.read(out, descriptor: profile)["hours"] == .list(["Mon 9-5", "Sat closed"]))
        #expect(out.contains("type: businessProfile"))   // unknown-to-schema key preserved
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --package-path . --filter TypedContentEditor 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TypedContentEditor' in scope`.

- [ ] **Step 3: Implement `TypedContentEditor`**

```swift
// Sources/AnglesiteCore/TypedContentEditor.swift
import Foundation

/// Bridges a content file to the typed, per-field values a form editor binds to, and back.
///
/// One `markdown` field per type (the `body`) maps to the document body; every other field maps to
/// a frontmatter key. `write` applies only fields whose value actually changed, so
/// `FrontmatterDocument`'s verbatim preservation keeps untouched keys and the body intact. Pure,
/// no I/O.
public enum TypedContentEditor {
    public enum FieldValue: Equatable, Sendable {
        case text(String)
        case flag(Bool)
        case date(Date?)
        case number(Double?)
        case list([String])
    }

    public struct Values: Equatable, Sendable {
        private var dict: [String: FieldValue]
        public init(_ dict: [String: FieldValue] = [:]) { self.dict = dict }
        public subscript(_ name: String) -> FieldValue? {
            get { dict[name] }
            set { dict[name] = newValue }
        }
    }

    public static func defaultValue(for kind: ContentTypeField.Kind) -> FieldValue {
        switch kind {
        case .string, .text, .markdown, .url, .image: return .text("")
        case .bool: return .flag(false)
        case .date, .datetime: return .date(nil)
        case .number: return .number(nil)
        case .stringArray, .imageArray: return .list([])
        }
    }

    public static func read(_ contents: String, descriptor: ContentTypeDescriptor) -> Values {
        let doc = FrontmatterDocument.parse(contents)
        var out = Values()
        for field in descriptor.fields {
            if field.kind == .markdown {
                out[field.name] = .text(doc.body)
                continue
            }
            guard let raw = doc.value(for: field.name) else {
                out[field.name] = defaultValue(for: field.kind)
                continue
            }
            out[field.name] = decode(raw, kind: field.kind)
        }
        return out
    }

    public static func write(_ values: Values, into contents: String, descriptor: ContentTypeDescriptor) -> String {
        var doc = FrontmatterDocument.parse(contents)
        let current = read(contents, descriptor: descriptor)
        for field in descriptor.fields {
            guard let newValue = values[field.name], newValue != current[field.name] else { continue }
            if field.kind == .markdown {
                if case .text(let body) = newValue { doc.body = body }
                continue
            }
            if let encoded = encode(newValue, kind: field.kind) { doc.set(encoded, for: field.name) }
        }
        return doc.serialized()
    }

    // MARK: Decode (frontmatter → field value)

    private static func decode(_ value: FrontmatterValue, kind: ContentTypeField.Kind) -> FieldValue {
        switch kind {
        case .string, .text, .url, .image, .markdown:
            if case .string(let s) = value { return .text(s) }
            return .text("")
        case .bool:
            if case .bool(let b) = value { return .flag(b) }
            return .flag(false)
        case .date, .datetime:
            if case .string(let s) = value { return .date(parseDate(s)) }
            return .date(nil)
        case .number:
            if case .string(let s) = value { return .number(Double(s)) }
            return .number(nil)
        case .stringArray, .imageArray:
            if case .array(let a) = value { return .list(a) }
            return .list([])
        }
    }

    // MARK: Encode (field value → frontmatter)

    private static func encode(_ value: FieldValue, kind: ContentTypeField.Kind) -> FrontmatterValue? {
        switch value {
        case .text(let s): return .string(s)
        case .flag(let b): return .bool(b)
        case .date(let d): return .string(d.map { format($0, kind: kind) } ?? "")
        case .number(let n): return .string(n.map { formatNumber($0) } ?? "")
        case .list(let a): return .array(a)
        }
    }

    // MARK: Date/number formatting (mirror ContentScaffold)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func format(_ date: Date, kind: ContentTypeField.Kind) -> String {
        let full = iso.string(from: date)
        return kind == .date ? String(full.prefix(10)) : full
    }

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        // date-only (yyyy-MM-dd) → midnight UTC
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .iso8601)
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    private static func formatNumber(_ n: Double) -> String {
        n.rounded() == n ? String(Int(n)) : String(n)
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --package-path . --filter TypedContentEditor 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteCore/TypedContentEditor.swift Tests/AnglesiteCoreTests/TypedContentEditorTests.swift
git commit -m "$(printf 'feat(#346): TypedContentEditor maps descriptor fields to typed values\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: `ContentTypeResolver` — path → descriptor (Core)

**Files:**
- Create: `Sources/AnglesiteCore/ContentTypeResolver.swift`
- Test: `Tests/AnglesiteCoreTests/ContentTypeResolverTests.swift`

**Interfaces:**
- Consumes: `ContentTypeRegistry`/`ContentTypeDescriptor` (existing).
- Produces: `public enum ContentTypeResolver { public static func descriptor(forRelativePath path: String, registry: ContentTypeRegistry = ContentTypeRegistry()) -> ContentTypeDescriptor? }`

Rules (pure, no I/O):
1. Collection types: if the normalized path contains the segment sequence `src/content/<collection>/…`, return the descriptor whose `collection == <collection>`.
2. Page singletons: a fixed map of `descriptor.id → relative page path`; `businessProfile → "src/pages/about.md"`. Exact match → that descriptor.
3. Otherwise `nil`.

- [ ] **Step 1: Write failing tests**

```swift
// Tests/AnglesiteCoreTests/ContentTypeResolverTests.swift
import Testing
@testable import AnglesiteCore

@Suite("ContentTypeResolver")
struct ContentTypeResolverTests {
    @Test("collection entry resolves by directory")
    func collection() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/content/notes/hello.md")?.id == "note")
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/content/events/launch.md")?.id == "event")
    }

    @Test("businessProfile resolves by its singleton page path")
    func businessProfile() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/pages/about.md")?.id == "businessProfile")
    }

    @Test("leading ./ and absolute-ish prefixes are tolerated")
    func normalization() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "./src/content/articles/x.md")?.id == "article")
    }

    @Test("unrelated files resolve to nil (text fallback)")
    func none() {
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/pages/index.astro") == nil)
        #expect(ContentTypeResolver.descriptor(forRelativePath: "src/styles/global.css") == nil)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --package-path . --filter ContentTypeResolver 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ContentTypeResolver' in scope`.

- [ ] **Step 3: Implement `ContentTypeResolver`**

```swift
// Sources/AnglesiteCore/ContentTypeResolver.swift
import Foundation

/// Resolves a project-relative file path to its content type, so the app can open typed files in
/// the form editor. Collection entries are matched by their `src/content/<collection>/` directory;
/// page-stored singletons by a fixed path map. Pure, no I/O.
public enum ContentTypeResolver {
    /// Canonical singleton page paths for `.page`-stored types. `businessProfile` is shipped in the
    /// template at `src/pages/about.md` (this PR; the editor-relevant slice of #388).
    static let pagePaths: [String: String] = ["businessProfile": "src/pages/about.md"]

    public static func descriptor(
        forRelativePath path: String,
        registry: ContentTypeRegistry = ContentTypeRegistry()
    ) -> ContentTypeDescriptor? {
        let normalized = normalize(path)

        // 1. Collection entry by directory.
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4, parts[0] == "src", parts[1] == "content" {
            let collection = parts[2]
            if let match = registry.all.first(where: { $0.collection == collection }) { return match }
        }

        // 2. Page singleton by exact path.
        for (id, pagePath) in pagePaths where normalized == pagePath {
            return registry.descriptor(id: id)
        }
        return nil
    }

    private static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --package-path . --filter ContentTypeResolver 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteCore/ContentTypeResolver.swift Tests/AnglesiteCoreTests/ContentTypeResolverTests.swift
git commit -m "$(printf 'feat(#346): ContentTypeResolver maps project paths to content types\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: `businessProfile` singleton page in the template

**Files:**
- Create: `Resources/Template/src/pages/about.md`

**Interfaces:** none (template asset). Consumed at runtime by `ContentTypeResolver` (Task 3) and the editor (Tasks 5–7).

Rationale: `businessProfile` is the only `.page`-stored type and had no on-disk home. This ships one. It carries a `type: businessProfile` frontmatter marker (for downstream identification / #388 rendering and external tooling) plus the descriptor's fields. It uses `BaseLayout` + a `title` so the page builds and renders within the site shell today; the h-card / `LocalBusiness` JSON-LD **rendering** is deferred to #388. The `type`, `layout`, and `title` keys are not in the `businessProfile` schema and are preserved verbatim by the form editor (Task 1 guarantee), so editing business fields never disturbs them.

- [ ] **Step 1: Create the page**

```markdown
---
layout: ../layouts/BaseLayout.astro
title: "About"
type: businessProfile
name: "Your Business Name"
description: ""
telephone: ""
email: ""
streetAddress: ""
locality: ""
region: ""
postalCode: ""
hours: []
url: ""
---

# About

Edit your business details in Anglesite (File ▸ open this page).
```

- [ ] **Step 2: Verify it parses as the businessProfile type (reuses Task 3)**

Add a focused assertion to `ContentTypeResolverTests` is unnecessary (already covered). Instead verify the field read works end-to-end with a quick test addition:

```swift
// Append to TypedContentEditorTests.swift
@Test("template about.md reads as businessProfile with marker preserved")
func aboutPage() {
    let profile = ContentTypeRegistry().descriptor(id: "businessProfile")!
    let src = """
    ---
    layout: ../layouts/BaseLayout.astro
    title: "About"
    type: businessProfile
    name: "Your Business Name"
    hours: []
    url: ""
    ---

    # About
    """ + "\n"
    let v = TypedContentEditor.read(src, descriptor: profile)
    #expect(v["name"] == .text("Your Business Name"))
    var dict = [String: TypedContentEditor.FieldValue]()
    for f in profile.fields { dict[f.name] = v[f.name] }
    dict["name"] = .text("Acme Co")
    let out = TypedContentEditor.write(TypedContentEditor.Values(dict), into: src, descriptor: profile)
    #expect(out.contains("name: \"Acme Co\""))
    #expect(out.contains("type: businessProfile"))           // marker preserved
    #expect(out.contains("layout: ../layouts/BaseLayout.astro")) // layout preserved
}
```

- [ ] **Step 3: Run the test**

Run: `swift test --package-path . --filter TypedContentEditor 2>&1 | tail -20`
Expected: PASS (6 tests now).

- [ ] **Step 4: (If node available) verify the template still builds**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors/Resources/Template
[ -d node_modules ] && npx astro build 2>&1 | tail -15 || echo "SKIP: node_modules absent — build smoke skipped"
```
Expected: build succeeds (or SKIP). If `astro build` errors on `about.md`, confirm `BaseLayout.astro` tolerates extra frontmatter props (it should — Astro passes frontmatter through); do not add schema validation for pages.

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Resources/Template/src/pages/about.md Tests/AnglesiteCoreTests/TypedContentEditorTests.swift
git commit -m "$(printf 'feat(#346): ship businessProfile singleton page (src/pages/about.md)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 5: `TypedEntryEditorModel` — observable buffer (App)

**Files:**
- Create: `Sources/AnglesiteApp/TypedEntryEditorModel.swift`

**Interfaces:**
- Consumes: `TypedContentEditor` (Task 2), `FileDocumentIO` (existing), `NativeContentOperations.processGitCommit` (existing), `FileRef`/`ContentTypeDescriptor` (existing).
- Produces (used by Task 6/7):
  - `@MainActor @Observable final class TypedEntryEditorModel`
  - `init(file: FileRef, descriptor: ContentTypeDescriptor, sourceDirectory: URL, gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit)`
  - `let file: FileRef`, `let descriptor: ContentTypeDescriptor`
  - `var values: TypedContentEditor.Values` (bound by the view)
  - `var isDirty: Bool`, `var loadError: String?`, `var isLoading: Bool`, `var conflictDiskContents: String?`
  - `func load() async`, `@discardableResult func save() async -> Bool`, `func flushBeforeLeaving() async -> Bool`, `func checkExternalChange() async`, `func keepMyChanges()`, `func reloadFromDisk() async`
  - Binding helpers: `func textBinding(_ name: String) -> Binding<String>`, `func boolBinding(_ name: String) -> Binding<Bool>`, `func dateBinding(_ name: String) -> Binding<Date>`, `func numberBinding(_ name: String) -> Binding<String>`, `func listBinding(_ name: String) -> Binding<[String]>`.

This mirrors `FileEditorModel` (Task reference: `Sources/AnglesiteApp/FileEditorModel.swift`) but holds typed `values` + the raw loaded `contents` (for verbatim writes) instead of a single `text` buffer, and commits after each save.

- [ ] **Step 1: Implement the model**

```swift
// Sources/AnglesiteApp/TypedEntryEditorModel.swift
import Foundation
import SwiftUI
import Observation
import AnglesiteCore

/// Editor state for one open *typed* content file. Parallels `FileEditorModel` but exposes the
/// file as per-field `TypedContentEditor.Values` (bound by `TypedEntryEditorView`) and commits each
/// save to git. The raw loaded `contents` is retained so writes go through
/// `TypedContentEditor.write`, which preserves untouched keys, unknown keys, and the body verbatim.
/// All disk IO runs off the main actor.
@MainActor
@Observable
final class TypedEntryEditorModel {
    let file: FileRef
    let descriptor: ContentTypeDescriptor
    private let sourceDirectory: URL
    private let gitCommit: NativeContentOperations.GitCommit

    var values: TypedContentEditor.Values = .init()
    private var savedValues: TypedContentEditor.Values = .init()
    private var contents: String = ""               // last-loaded/saved file text (verbatim base)
    private var lastModified: Date?
    private(set) var loadError: String?
    private(set) var isLoading = false
    var conflictDiskContents: String?

    var isDirty: Bool { values != savedValues && loadError == nil && !isLoading }

    init(file: FileRef,
         descriptor: ContentTypeDescriptor,
         sourceDirectory: URL,
         gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit) {
        self.file = file
        self.descriptor = descriptor
        self.sourceDirectory = sourceDirectory
        self.gitCommit = gitCommit
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = file.url
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try FileDocumentIO.load(url) }.value
            adopt(loaded.contents)
            lastModified = loaded.modificationDate
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isDirty else { return true }
        let descriptor = self.descriptor
        let base = contents
        let edited = values
        let newContents = TypedContentEditor.write(edited, into: base, descriptor: descriptor)
        let url = file.url
        do {
            let mtime = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.save(newContents, to: url)
            }.value
            lastModified = mtime
            contents = newContents
            savedValues = edited
            await commit()
            return true
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func flushBeforeLeaving() async -> Bool {
        guard isDirty else { return true }
        let url = file.url
        let known = lastModified
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: true)
        }.value
        if case .conflict(let disk)? = change { conflictDiskContents = disk; return false }
        return await save()
    }

    func checkExternalChange() async {
        guard loadError == nil else { return }
        let url = file.url
        let known = lastModified
        let dirty = isDirty
        let change = try? await Task.detached(priority: .userInitiated) {
            try FileDocumentIO.externalChange(at: url, lastKnownModificationDate: known, bufferIsDirty: dirty)
        }.value
        switch change {
        case .reloadable(let disk):
            adopt(disk); lastModified = await freshModificationDate()
        case .conflict(let disk):
            conflictDiskContents = disk
        case .none, nil:
            break
        }
    }

    func keepMyChanges() { conflictDiskContents = nil }

    func reloadFromDisk() async {
        guard let disk = conflictDiskContents else { return }
        adopt(disk)
        lastModified = await freshModificationDate()
        conflictDiskContents = nil
    }

    // MARK: Bindings used by the view

    func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { if case .text(let s)? = self.values[name] { return s }; return "" },
                set: { self.values[name] = .text($0) })
    }
    func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { if case .flag(let b)? = self.values[name] { return b }; return false },
                set: { self.values[name] = .flag($0) })
    }
    func dateBinding(_ name: String) -> Binding<Date> {
        Binding(get: { if case .date(let d?)? = self.values[name] { return d }; return Date(timeIntervalSince1970: 0) },
                set: { self.values[name] = .date($0) })
    }
    func numberBinding(_ name: String) -> Binding<String> {
        Binding(get: { if case .number(let n?)? = self.values[name] {
                           return n.rounded() == n ? String(Int(n)) : String(n) }; return "" },
                set: { self.values[name] = .number(Double($0)) })
    }
    func listBinding(_ name: String) -> Binding<[String]> {
        Binding(get: { if case .list(let a)? = self.values[name] { return a }; return [] },
                set: { self.values[name] = .list($0) })
    }

    // MARK: Private

    private func adopt(_ text: String) {
        contents = text
        let read = TypedContentEditor.read(text, descriptor: descriptor)
        values = read
        savedValues = read
    }

    private func commit() async {
        let rel = relativePath(of: file.url, under: sourceDirectory)
        let slug = file.url.deletingPathExtension().lastPathComponent
        _ = await gitCommit(sourceDirectory, rel, "anglesite: edit \(descriptor.id) \(slug)")
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let u = url.standardizedFileURL.path(percentEncoded: false)
        let r = root.standardizedFileURL.path(percentEncoded: false)
        if u.hasPrefix(r) { return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description }
        return url.lastPathComponent
    }

    private func freshModificationDate() async -> Date? {
        let url = file.url
        return try? await Task.detached(priority: .userInitiated) { try FileDocumentIO.load(url).modificationDate }.value
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
swift build --package-path . 2>&1 | tail -20
```
Expected: builds clean (the SPM library builds `AnglesiteApp` sources). Fix any actor/`Sendable`/`Binding` errors before proceeding. (Note: `swift build` compiles the package; the full app bundle needs `xcodebuild`, deferred to Task 7's verification.)

- [ ] **Step 3: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/TypedEntryEditorModel.swift
git commit -m "$(printf 'feat(#346): TypedEntryEditorModel observable buffer over TypedContentEditor\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 6: `TypedEntryEditorView` — generic form (App)

**Files:**
- Create: `Sources/AnglesiteApp/TypedEntryEditorView.swift`

**Interfaces:**
- Consumes: `TypedEntryEditorModel` (Task 5), `ContentTypeField.Kind` (existing).
- Produces: `struct TypedEntryEditorView: View` taking `@Bindable var model: TypedEntryEditorModel`.

Renders a `Form` iterating `model.descriptor.fields` in order, one control per `Kind`. Header + dirty dot + Save button + conflict alert mirror `MainPaneEditorView`. The single `markdown` field renders last as a full-width `TextEditor` labeled "Body".

- [ ] **Step 1: Implement the view**

```swift
// Sources/AnglesiteApp/TypedEntryEditorView.swift
import SwiftUI
import AnglesiteCore

/// Generic, schema-driven form editor for a typed content file. One control per field `Kind`,
/// ordered by the descriptor. State lives in `TypedEntryEditorModel` (owned by `SiteWindow`) so
/// navigating away auto-saves and the buffer survives the Preview/Editor toggle.
struct TypedEntryEditorView: View {
    @Bindable var model: TypedEntryEditorModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let loadError = model.loadError {
                    ContentUnavailableView {
                        Label("Can't open \(model.file.name)", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.file.url]) }
                    }
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.file.id) { await model.load() }
        .onChange(of: controlActiveState) { _, new in
            if new == .key { Task { await model.checkExternalChange() } }
        }
        .background(Button("") { Task { await model.save() } }
            .keyboardShortcut("s", modifiers: [.command]).hidden())
        .alert("\(model.file.name) changed on disk", isPresented: conflictBinding) {
            Button("Keep My Changes", role: .cancel) { model.keepMyChanges() }
            Button("Reload from Disk") { Task { await model.reloadFromDisk() } }
        } message: {
            Text("Another tool edited this file while you had unsaved changes.")
        }
    }

    private var form: some View {
        Form {
            ForEach(scalarFields, id: \.name) { field in
                control(for: field)
            }
            if let body = bodyField {
                Section("Body") {
                    TextEditor(text: model.textBinding(body.name))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var scalarFields: [ContentTypeField] { model.descriptor.fields.filter { $0.kind != .markdown } }
    private var bodyField: ContentTypeField? { model.descriptor.fields.first { $0.kind == .markdown } }

    @ViewBuilder
    private func control(for field: ContentTypeField) -> some View {
        let label = field.name + (field.required ? " *" : "")
        switch field.kind {
        case .string, .url, .image:
            HStack {
                TextField(label, text: model.textBinding(field.name))
                if field.kind == .image {
                    Button("Choose…") { chooseFile(for: field.name) }
                }
            }
        case .text:
            VStack(alignment: .leading) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField(label, text: model.textBinding(field.name), axis: .vertical).lineLimit(2...6)
            }
        case .bool:
            Toggle(label, isOn: model.boolBinding(field.name))
        case .date, .datetime:
            DatePicker(label, selection: model.dateBinding(field.name),
                       displayedComponents: field.kind == .date ? [.date] : [.date, .hourAndMinute])
        case .number:
            TextField(label, text: model.numberBinding(field.name))
        case .stringArray, .imageArray:
            StringListEditor(title: label, items: model.listBinding(field.name),
                             pickFile: field.kind == .imageArray)
        case .markdown:
            EmptyView()   // handled by the Body section
        }
    }

    private func chooseFile(for name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.textBinding(name).wrappedValue = url.lastPathComponent
        }
    }

    private var header: some View {
        HStack {
            Label(model.file.name, systemImage: "doc.text").font(.headline)
            if model.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
            }
            Spacer()
            Button("Save") { Task { await model.save() } }.disabled(!model.isDirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflictDiskContents != nil }, set: { _ in })
    }
}

/// A minimal add/remove list editor for `stringArray` / `imageArray` fields (tags, hours, album
/// images).
private struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    var pickFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(items.indices, id: \.self) { i in
                HStack {
                    TextField("", text: Binding(get: { items[i] }, set: { items[i] = $0 }))
                    Button(role: .destructive) { items.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button { items.append("") } label: { Label("Add", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                if pickFile {
                    Button("Choose…") { chooseFile() }
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { items.append(url.lastPathComponent) }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift build --package-path . 2>&1 | tail -20`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/TypedEntryEditorView.swift
git commit -m "$(printf 'feat(#346): TypedEntryEditorView schema-driven form per field Kind\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 7: Wire typed editor into `SiteWindow` routing

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `ContentTypeResolver` (Task 3), `TypedEntryEditorModel` (Task 5), `TypedEntryEditorView` (Task 6).

Add a `.typed` case to the private `ActiveEditor` enum, resolve the descriptor in `applyNavigatorSelection` before the existing `EditorKind` switch, and host `TypedEntryEditorView` in `mainPaneContent`. Resolution is by project-relative path (`ContentTypeResolver`), so it needs `site.sourceDirectory` — already in scope in these methods.

- [ ] **Step 1: Add the `.typed` case to `ActiveEditor`**

In `Sources/AnglesiteApp/SiteWindow.swift`, the `private enum ActiveEditor` (around line 12):

```swift
private enum ActiveEditor {
    case text(FileEditorModel)
    case plist(PlistEditorModel)
    case typed(TypedEntryEditorModel)

    var file: FileRef {
        switch self {
        case .text(let model): model.file
        case .plist(let model): model.file
        case .typed(let model): model.file
        }
    }
}
```

- [ ] **Step 2: Host the view in `mainPaneContent`**

In `mainPaneContent(for:)` (around line 548), add a branch alongside `.text`/`.plist`:

```swift
case .editor:
    if case .text(let editorModel) = activeEditor {
        MainPaneEditorView(model: editorModel)
    } else if case .typed(let typedModel) = activeEditor {
        TypedEntryEditorView(model: typedModel)
    } else if case .plist(let plistEditorModel) = activeEditor {
        PlistEditorView(model: plistEditorModel) { title in
            Task { await saveWebsiteTitle(title) }
        }
    } else {
        previewPane(for: site)
    }
```

- [ ] **Step 3: Resolve the descriptor in `applyNavigatorSelection`**

In the `.file(let file)` branch (around line 669), before the `EditorKind.resolve` switch, attempt typed resolution. Replace the `switch EditorKind.resolve(for: file)` block with:

```swift
Task {
    guard await leaveCurrentEditor() else { return }   // flush the previous file first
    if let source = site?.sourceDirectory,
       let descriptor = ContentTypeResolver.descriptor(
           forRelativePath: relativeProjectPath(of: file.url, under: source)) {
        activeEditor = .typed(TypedEntryEditorModel(
            file: file, descriptor: descriptor, sourceDirectory: source))
    } else {
        switch EditorKind.resolve(for: file) {
        case .text:
            activeEditor = .text(FileEditorModel(file: file))
        case .plist:
            activeEditor = .plist(PlistEditorModel(
                file: file,
                websiteTitle: site?.name ?? file.name,
                sourceDirectory: site?.sourceDirectory ?? file.url.deletingLastPathComponent()))
        }
    }
    mainPaneMode = .editor(file)
}
```

Add this private helper to `SiteWindow` (near the other private helpers, e.g. after `applyNavigatorSelection`):

```swift
/// Project-relative path of `url` under the site `Source/` directory, for content-type resolution.
private func relativeProjectPath(of url: URL, under root: URL) -> String {
    let u = url.standardizedFileURL.path(percentEncoded: false)
    let r = root.standardizedFileURL.path(percentEncoded: false)
    guard u.hasPrefix(r) else { return url.lastPathComponent }
    return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description
}
```

- [ ] **Step 4: Verify `leaveCurrentEditor` flushes the typed editor**

Find `leaveCurrentEditor` in `SiteWindow.swift` (search: `func leaveCurrentEditor`). It switches over `activeEditor` to call `flushBeforeLeaving()`. Add a `.typed` arm mirroring `.text`/`.plist`:

```bash
grep -n "func leaveCurrentEditor" -A 20 Sources/AnglesiteApp/SiteWindow.swift
```
If it switches on `activeEditor`, add:
```swift
case .typed(let model): return await model.flushBeforeLeaving()
```
If it instead pattern-matches only `.text`/`.plist` for conflict handling, mirror that exact structure for `.typed`. (Implementer: match the existing shape — do not restructure.)

- [ ] **Step 5: Build the app target**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
# Worktree prep (memory: copy-plugin + xcodegen needed for a fresh worktree app build):
export ANGLESITE_PLUGIN_SRC="$(cd ../../../anglesite 2>/dev/null && pwd)"
scripts/copy-plugin.sh 2>&1 | tail -3 || true
xcodegen generate 2>&1 | tail -3
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -25
```
Expected: **BUILD SUCCEEDED**. If `copy-plugin.sh` fails because `ANGLESITE_PLUGIN_SRC` is unset/wrong, point it at the real plugin checkout (`…/github.com/Anglesite/anglesite`). If the build hits the `Resources/plugin` self-symlink error, `rm` the self-pointing symlink and re-run `copy-plugin.sh` (memory).

- [ ] **Step 6: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(printf 'feat(#346): route typed content files to the form editor\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 8: Full verification + PR

**Files:** none (verification + integration).

- [ ] **Step 1: Run the full Core test suite**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
swift test --package-path . 2>&1 | tail -25
```
Expected: all tests pass, including the new `FrontmatterDocument`, `TypedContentEditor`, `ContentTypeResolver` suites. (If the MCP/apply-edit e2e tests fail for lack of `ANGLESITE_PLUGIN_PATH`/node, that is the known environment gap — confirm the *new* suites pass and the failures are only those e2e ones.)

- [ ] **Step 2: Manual smoke (app)**

Launch the built app, open a site, and:
1. Select a note/article/event entry → confirm it opens in the form (not the text editor); edit a field + the body; Save; confirm the file on disk updated and `git log -1` in `Source/` shows the per-edit commit.
2. Open `about.md` → confirm it opens as the Business Profile form; edit `name` + add an `hours` row; Save; confirm `type: businessProfile` and `layout:` keys are untouched in the file.
3. Open a non-typed file (e.g. a CSS file) → confirm it still opens in the plain text editor.

Record results in the PR description.

- [ ] **Step 3: Push and open the PR**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git push -u origin feat/346-typed-editors
gh pr create --title "feat(#346): V-1.4 per-type SwiftUI form editors" --body "$(cat <<'EOF'
Closes #346.

Schema-driven form editor for all 11 typed content objects. Opening a typed content file shows a structured form (one control per field Kind) instead of raw markdown; edits round-trip to YAML frontmatter and commit per save.

## What landed
- `FrontmatterDocument` (Core): round-trip-safe frontmatter+body model — unedited round-trips are the identity; editing one field preserves untouched keys, unknown keys, comments, and the body verbatim.
- `TypedContentEditor` (Core): maps descriptor fields ⟷ typed values; markdown field ⟷ body; writes only changed fields.
- `ContentTypeResolver` (Core): project path → descriptor.
- `TypedEntryEditorModel` + `TypedEntryEditorView` (App): observable buffer + generic SwiftUI form, wired into `SiteWindow` navigator routing.
- `businessProfile` singleton shipped at `Resources/Template/src/pages/about.md` (settles the editor-relevant slice of #388 — *location only*, not h-card/JSON-LD rendering).

## Out of scope
- h-card / schema.org JSON-LD rendering (V-1.7 #349, V-1.8 #350, #388 rendering).
- Form↔source toggle (form-only by design).
- App-Intent entities (V-1.9 #351).

## Testing
- New Core unit suites: `FrontmatterDocument`, `TypedContentEditor`, `ContentTypeResolver` — all green under `swift test`.
- App target builds (`xcodebuild -scheme Anglesite`).
- Manual smoke: [fill in results from Task 8 Step 2].

Design: `docs/superpowers/specs/2026-06-27-v1-4-typed-form-editors-design.md`
Plan: `docs/superpowers/plans/2026-06-27-v1-4-typed-form-editors.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Schema-driven generic editor → Tasks 2, 6. ✓
- Form-only (markdown body in form) → Task 6 Body section; `markdown`↔body in Task 2. ✓
- All 11 types incl. businessProfile → Task 4 (location) + resolver Task 3 + generic engine. ✓
- Round-trip-safe frontmatter serializer preserving unknown keys + body → Task 1. ✓
- Type resolution (collection dir + businessProfile marker/path) → Task 3. (Note: design mentioned a frontmatter `type:` marker for robustness; the resolver uses the canonical **path** for the singleton, and the marker is still written into `about.md` for downstream/#388 use — equivalent for routing, no inline I/O. The marker's preservation is covered by Task 4's test.) ✓
- Per-edit git commit → Task 5 `commit()` via `processGitCommit`. ✓
- Wiring into SiteWindow mirroring `.plist` → Task 7. ✓
- Error handling (load error, external-change conflict, malformed frontmatter → text fallback) → Task 5 + Task 7 (resolver returns nil ⟹ text editor). ✓
- Testing strategy (logic in Core, app build-validated) → Tasks 1–4 tested; 5–7 built. ✓

**Placeholder scan:** No TBD/TODO. The only deferred-to-implementer judgement is Task 7 Step 4 (match the existing `leaveCurrentEditor` shape) — bounded with an exact grep and explicit "mirror, don't restructure" instruction. ✓

**Type consistency:** `FrontmatterValue` (reused), `TypedContentEditor.FieldValue`/`.Values`, `ContentTypeResolver.descriptor(forRelativePath:registry:)`, `TypedEntryEditorModel` init signature, and the `NativeContentOperations.GitCommit` typealias are used identically across tasks. Binding helper names (`textBinding`/`boolBinding`/`dateBinding`/`numberBinding`/`listBinding`) match between Task 5 (definition) and Task 6 (use). ✓
