# RSVP, Check-in, and Repost Post Types Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an Anglesite site author RSVP, check-in, and repost entries — publishable from the app's composer, round-tripping through external Micropub clients, and appearing in feeds — closing the three `return null` guards Post Type Discovery already documents as unsupported.

**Architecture:** Three new `ContentTypeDescriptor`s in the existing registry, following the exact shape reply/like/bookmark already use (h-entry, titleless-or-simple, `lang`/`draft` bookends). One new closed-vocabulary field kind (`ContentTypeField.Kind.enum`) threads through every place `Kind` is already exhaustively switched on. Astro/worker changes mirror the same collections into `content.config.ts`, `Hentry.astro`, `feeds.ts`, and `post-type-discovery.ts`.

**Tech Stack:** Swift 6.4 (AnglesiteCore, AnglesiteApp, AnglesiteMobile, AnglesiteIntents), Swift Testing, Astro 5 / Zod (Resources/Template), Vitest + Node's `node:test`.

**Spec:** [`docs/superpowers/specs/2026-09-02-rsvp-checkin-repost-post-types-design.md`](../specs/2026-09-02-rsvp-checkin-repost-post-types-design.md) — this plan refines two details the spec left at the field-table level:
- Every personal (h-entry-family) descriptor follows a `lang` (first) / `draft` (last) bookend, with a required `publishDate: .datetime`. The spec's three field tables omitted `lang`/`publishDate`/`draft` for brevity; this plan's descriptors include them, matching `reply`/`like`/`bookmark` exactly.
- Field names use the registry's existing `body`/`e-content` convention, not `content` as the spec prose said.
- Check-in's optional venue permalink is its own field (`venueUrl`, distinct from RSVP's `inReplyTo`) rendered by its own `Hentry.astro` branch — not literally the same branch as RSVP's, since they read different frontmatter keys (both project to `u-in-reply-to`).

## Global Constraints

- Swift: Xcode 27+ / Swift 6.4. Run local Swift suites via `scripts/swift-test.sh` (wraps `swift test`, holds the machine-scoped lock — see `docs/testing-macos-app.md`).
- Any `Resources/Template/` change requires also running `swift test` (`ContentConfigDriftTests` couples to the template's markup — see `AGENTS.md`/`CONTRIBUTING.md`).
- Template JS/TS: from `Resources/Template/`, `npm run test:worker` (vitest, covers `worker/*.test.ts`) and `npm test` (`tsx --test` + `npm run test:astro`, covers `src/**/*.test.ts`). This checkout has no `node_modules` yet — run `npm install` once in `Resources/Template/` before the first test run.
- `ContentTypeField.Kind` is switched exhaustively (no `default:`) in 9 call sites across `Sources/` and 1 in `Tests/` — every one must gain an `.enum` arm in Task 1/2 or the build fails at that file. Task 1/2 list every site explicitly; do not rely on the compiler to "find them all" mid-task — it will, but only one file at a time, and the point of listing them here is to size the task correctly up front.
- Follow existing conventions exactly (field name casing, mf2 property strings, doc-comment style with a trailing issue reference `(#1598)` where the codebase's convention already does that for other fields).
- Commit after each task (or each numbered step group within Tasks 3–5, which are large) — small, reviewable commits, not one giant diff.

---

### Task 1: `ContentTypeField.Kind.enum` — Core plumbing

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift:21-67` (declare the case)
- Modify: `Sources/AnglesiteCore/TypedContentEditor.swift:50-59` (`defaultValue(for:)`), `:113-147` (`decode`)
- Modify: `Sources/AnglesiteCore/MicropubContentSync.swift:113-154` (`fieldValue(for:rawProperty:properties:)`)
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift:264-306` (`renderEntry`), `:346-358` (`renderSingleton`)
- Modify: `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift:45-61` (`zod(for:)`)
- Test: `Tests/AnglesiteCoreTests/TypedContentEditorTests.swift`, `Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift`, `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`, `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`

**Interfaces:**
- Produces: `ContentTypeField.Kind.enum(cases: [String])` — a new case every later task (2-5) can declare a field with. `TypedContentEditor.FieldValue` backing is `.text(String)` (same as `.string`/`.url`); no new `FieldValue` case.
- Produces: `ContentScaffold.renderEntry`'s `.enum` default is `cases.first ?? ""` when no value is supplied (never an empty string when `cases` is non-empty) — later tasks rely on this to scaffold a schema-valid RSVP status without needing to add `.enum` to `NewCollectionEntrySheet`'s required-field UI.

- [ ] **Step 1: Write the failing core round-trip test**

Add to `Tests/AnglesiteCoreTests/TypedContentEditorTests.swift`, right after the existing `.language` round-trip tests (after line 282, before the closing `}`):

```swift
    @Test("a .enum field round-trips through defaultValue/decode/encode exactly like .string")
    func enumFieldRoundTrips() {
        let descriptor = ContentTypeDescriptor(
            id: "test-enum", displayName: "Test", storage: .collection("test"),
            fields: [ContentTypeField("rsvp", .enum(cases: ["yes", "no", "maybe", "interested"]))],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: [:], schemaType: nil))
        #expect(TypedContentEditor.defaultValue(for: .enum(cases: ["yes", "no"])) == .text(""))
        let read = TypedContentEditor.read("---\nrsvp: maybe\n---\nBody.\n", descriptor: descriptor)
        #expect(read["rsvp"] == .text("maybe"))
        let written = TypedContentEditor.write(.init(["rsvp": .text("yes")]), into: "---\nrsvp: maybe\n---\nBody.\n", descriptor: descriptor)
        #expect(written.contains("rsvp: yes") || written.contains("rsvp: \"yes\""))
    }

    @Test("a missing .enum key decodes as an empty string, not a crash")
    func enumFieldMissingKey() {
        let descriptor = ContentTypeDescriptor(
            id: "test-enum-missing", displayName: "Test", storage: .collection("test"),
            fields: [ContentTypeField("rsvp", .enum(cases: ["yes", "no"]))],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: [:], schemaType: nil))
        let read = TypedContentEditor.read("---\ntitle: x\n---\nBody.\n", descriptor: descriptor)
        #expect(read["rsvp"] == .text(""))
    }
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `scripts/swift-test.sh --filter TypedContentEditorTests`
Expected: FAIL — `.enum` is not a member of `ContentTypeField.Kind` (compile error, not a runtime failure).

- [ ] **Step 3: Declare the `.enum` case**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, insert after the `.number` case (after line 44, before `/// An ordered list of strings...` / `case stringArray`):

```swift
        /// A closed set of allowed string values (e.g. RSVP status: yes/no/maybe/interested).
        /// Backed like `.string` (`TypedContentEditor.FieldValue.text`) — the only difference is
        /// which editor control renders it (a `Picker` over `cases`, instead of a free-text
        /// field) and which Zod expression the template layer generates (`z.enum([...])` instead
        /// of `z.string()`). First declared by the `rsvp` content type's `rsvp` field (#1598).
        case `enum`(cases: [String])
```

- [ ] **Step 4: Wire `.enum` into `TypedContentEditor`**

In `Sources/AnglesiteCore/TypedContentEditor.swift`, `defaultValue(for:)` (line 51-52): add `.enum` to the string-like bucket —

```swift
        case .string, .language, .text, .markdown, .url, .image, .enum: return .text("")
```

In `decode(_:kind:)` (line 114-117): add `.enum` to the string-like bucket —

```swift
        case .string, .language, .text, .url, .image, .markdown, .enum:
            if case .string(let s) = value { return .text(s) }
            return .text("")
```

`encode(_:kind:)` needs no change — it switches on `FieldValue`, not `Kind`, and `.enum` fields are always `.text(String)`, already handled by the existing `case .text(let s): return .string(s)` arm.

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/swift-test.sh --filter TypedContentEditorTests`
Expected: PASS (the two new tests, plus every existing test in the file still green).

- [ ] **Step 6: Write the failing `MicropubContentSync` test**

Add to `Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift`, near the existing `fieldValue`/`plainText` tests (after the `"fieldValue returns an empty records value for an objectArray field..."` test, around line 60):

```swift
    @Test("fieldValue reads an .enum field as plain text, same as .string")
    func fieldValueReadsEnumAsPlainText() {
        let field = ContentTypeField("rsvp", .enum(cases: ["yes", "no", "maybe", "interested"]))
        let properties: [String: [JSONValue]] = ["rsvp": [.string("yes")]]
        #expect(MicropubContentSync.fieldValue(for: field, rawProperty: "rsvp", properties: properties) == .text("yes"))
    }
```

- [ ] **Step 7: Run it to verify it fails to compile, then wire `.enum` into `MicropubContentSync.fieldValue`**

Run: `scripts/swift-test.sh --filter MicropubContentSyncTests` — expect a compile failure (non-exhaustive switch) once `.enum` exists (it does, from Step 3) but this switch doesn't handle it yet.

In `Sources/AnglesiteCore/MicropubContentSync.swift`, `fieldValue(for:rawProperty:properties:)` (line 119-120), add `.enum` to the string-like bucket:

```swift
        case .string, .language, .text, .url, .image, .markdown, .enum:
```

Run: `scripts/swift-test.sh --filter MicropubContentSyncTests`
Expected: PASS.

- [ ] **Step 8: Write the failing `ContentScaffold.renderEntry` test — default-first-case behavior**

Add to `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`, near the other `renderEntry` tests (after `"renderEntry uses a supplied markdown body and bool override (#531)"`, around line 461):

```swift
    @Test("renderEntry defaults an unsupplied .enum field to its first case, never an empty string (#1598)")
    func renderEntryEnumDefaultsToFirstCase() {
        let descriptor = ContentTypeDescriptor(
            id: "test-rsvp", displayName: "Test RSVP", storage: .collection("test-rsvps"),
            fields: [ContentTypeField("rsvp", .enum(cases: ["yes", "no", "maybe", "interested"]), required: true)],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: ["rsvp": "p-rsvp"], schemaType: nil))
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let out = ContentScaffold.renderEntry(descriptor: descriptor, title: nil, now: now)
        #expect(out.contains("rsvp: \"yes\""))
    }

    @Test("renderEntry renders a supplied .enum value instead of the first-case default")
    func renderEntryEnumUsesSuppliedValue() {
        let descriptor = ContentTypeDescriptor(
            id: "test-rsvp2", displayName: "Test RSVP", storage: .collection("test-rsvps2"),
            fields: [ContentTypeField("rsvp", .enum(cases: ["yes", "no", "maybe", "interested"]), required: true)],
            projections: ContentTypeProjections(microformat: "h-entry", microformatProperties: ["rsvp": "p-rsvp"], schemaType: nil))
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let out = ContentScaffold.renderEntry(descriptor: descriptor, title: nil, now: now, fieldValues: ["rsvp": "maybe"])
        #expect(out.contains("rsvp: \"maybe\""))
    }
```

- [ ] **Step 9: Run it to verify it fails to compile, then wire `.enum` into `ContentScaffold`**

In `Sources/AnglesiteCore/ContentScaffold.swift`, `renderEntry` (line 264-306): the existing `.string, .language, .text, .image` arm (line 292-293) writes `scalarValue(field, title:fieldValues:)`, which falls back to `""` — wrong for `.enum` (an empty string is never a valid case). Give `.enum` its own arm, placed right before the `.string, .language, .text, .image` arm:

```swift
            case .enum(let cases):
                let value = fieldValues[field.name] ?? cases.first ?? ""
                lines.append("\(field.name): \"\(escapeYAML(value))\"")
```

In `renderSingleton` (line 346-358): no built-in singleton uses `.enum` today, but the switch is exhaustive regardless — add it to the existing string-like bucket for compiler exhaustiveness (line 355):

```swift
            case .string, .language, .text, .url, .image, .date, .datetime, .enum:
                let filled = ContentTypeDescriptor.titleLikeFieldNames.contains(field.name) ? (name ?? "") : ""
                value = "\"\(escapeJSON(filled))\""
```

Run: `scripts/swift-test.sh --filter ContentScaffoldTests`
Expected: PASS.

- [ ] **Step 10: Write the failing drift-guard `zod(for:)` test**

Add to `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`, right after `"zod(for:) renders an objectArray field as z.array(z.object({...})) with member requiredness"` (around line 159):

```swift
    @Test("zod(for:) renders an enum field as z.enum([...]) with its cases quoted and ordered")
    func zodForEnum() {
        let kind = ContentTypeField.Kind.enum(cases: ["yes", "no", "maybe", "interested"])
        #expect(Self.zod(for: kind) == #"z.enum(["yes", "no", "maybe", "interested"])"#)
    }
```

- [ ] **Step 11: Run it to verify it fails to compile, then wire `.enum` into `zod(for:)`**

In `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`, `zod(for:)` (line 45-61): add a case right after `.number` (before `.stringArray, .imageArray`):

```swift
        case .enum(let cases):
            let quoted = cases.map { "\"\($0)\"" }.joined(separator: ", ")
            return "z.enum([\(quoted)])"
```

Run: `scripts/swift-test.sh --filter ContentConfigDriftTests`
Expected: PASS.

- [ ] **Step 12: Full Core build + suite check**

Run: `scripts/swift-test.sh --filter AnglesiteCoreTests`
Expected: PASS, zero failures. This confirms every `Kind` switch inside `AnglesiteCore` and its test target is now exhaustive over `.enum`.

- [ ] **Step 13: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Sources/AnglesiteCore/TypedContentEditor.swift Sources/AnglesiteCore/MicropubContentSync.swift Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift Tests/AnglesiteCoreTests/TypedContentEditorTests.swift Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "$(cat <<'EOF'
feat(#1598): add ContentTypeField.Kind.enum core plumbing

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `.enum` in the SwiftUI editors (macOS + iOS)

**Files:**
- Modify: `Sources/AnglesiteApp/TypedEntryEditorView.swift:44-80` (`TypedEntryForm.control`), `:227-259` (`ObjectArrayEditor.memberControl`)
- Modify: `Sources/AnglesiteMobile/ComposeScreen.swift:260-298` (`control(for:)`), `:577-598` (`memberControl`)

**Interfaces:**
- Consumes: `ContentTypeField.Kind.enum(cases: [String])` from Task 1.
- Produces: nothing new consumed elsewhere — this task only makes the two SwiftUI forms compile and render `.enum` fields. No new public API.

There is no dedicated unit-test target for these SwiftUI view bodies (confirmed: no test file references `TypedEntryEditorView`/`ComposeScreen`) — the compiler's switch-exhaustiveness check *is* the test for this task. Each step below is verified by a full build, not `swift test`.

- [ ] **Step 1: Add the `.enum` case to `TypedEntryForm.control(for:)`**

In `Sources/AnglesiteApp/TypedEntryEditorView.swift`, `control(for:)` (line 44-80): add a case right after `.number` (before `.stringArray, .imageArray`):

```swift
        case .enum(let cases):
            Picker(label, selection: model.textBinding(field.name)) {
                ForEach(cases, id: \.self) { Text($0) }
            }
```

- [ ] **Step 2: Add the `.enum` case to `ObjectArrayEditor.memberControl(for:in:rowID:)`**

In the same file, `memberControl` (line 227-259): no built-in `.objectArray` field uses `.enum` today, but the switch is deliberately exhaustive with no catch-all for kinds a member field must not use. Add `.enum` to the existing unsupported-member-kind arm (line 252):

```swift
        case .markdown, .stringArray, .imageArray, .objectArray, .enum:
```

(Text stays as-is: `"\(field.name) — unsupported member field kind"`.)

- [ ] **Step 3: Build the macOS app target to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Add the `.enum` case to iOS `control(for:)`**

In `Sources/AnglesiteMobile/ComposeScreen.swift`, `control(for:)` (line 260-298): add a case right after `.number` (before `.stringArray`):

```swift
        case .enum(let cases):
            Picker(label, selection: model.textBinding(field.name)) {
                ForEach(cases, id: \.self) { Text($0) }
            }
```

- [ ] **Step 5: Add the `.enum` case to iOS `ObjectArrayEditor.memberControl`**

In the same file (line 577-598), mirror the macOS catch-all (line 597):

```swift
        case .markdown, .stringArray, .imageArray, .objectArray, .enum:
```

- [ ] **Step 6: Build the iOS `AnglesiteMobile` scheme to verify it compiles**

`AnglesiteMobile` is an Xcode-only target (declared in `project.yml`, not `Package.swift` — no `swift build`/`swift test` coverage), so verify it via `xcodebuild` against an iOS Simulator destination:

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/TypedEntryEditorView.swift Sources/AnglesiteMobile/ComposeScreen.swift
git commit -m "$(cat <<'EOF'
feat(#1598): render ContentTypeField.Kind.enum as a Picker

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: RSVP content type

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift:297, 427-467` (`personalTypes`, insert after `like`)
- Modify: `Sources/AnglesiteIntents/ContentTypeAppEnum.swift` (new case, display representation)
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift` (new descriptor test + 4 existing tests to extend)
- Modify: `Resources/Template/src/content.config.ts:87-96, 165` (insert `rsvps` collection, add to export)
- Modify: `Resources/Template/src/lib/collections.ts:7-10` (add to `HENTRY_COLLECTIONS`)
- Modify: `Resources/Template/src/layouts/Hentry.astro:24-38, 91-96` (interface + render branch)
- Modify: `Resources/Template/worker/post-type-discovery.ts:1-10, 42-48` (flip `rsvp` guard, update doc comment)
- Test: `Resources/Template/worker/post-type-discovery.test.ts:93-102`
- Modify: `Resources/Template/src/lib/feeds.ts:6-10, 61-70, 120-132` (`FEED_COLLECTIONS`, `interactionContentFallback`, doc comment)
- Test: `Resources/Template/src/lib/feeds.test.ts:24-29, after 429`

**Interfaces:**
- Consumes: `ContentTypeField.Kind.enum(cases:)` (Task 1).
- Produces: registry id `"rsvp"`, collection `"rsvps"`, mf2 `h-entry` with `u-in-reply-to` + `p-rsvp`. Later tasks (check-in, repost) don't depend on this one — the three are independent verticals sharing only the Task 1/2 plumbing.
- No change needed to `Resources/Template/src/lib/schema.ts`: `hentrySchema`'s `switch (collection)` (around line 163) already ends in `default: return null;`, so `rsvps`/`checkins`/`reposts` (added to the `EntryCollection` union via `HENTRY_COLLECTIONS` in Step 9) automatically get no JSON-LD, matching `likes` — exactly what the design spec calls for, for free.

- [ ] **Step 1: Write the failing registry test**

Add to `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, right after `likeDescriptor()` (around line 236):

```swift
    @Test("rsvp is an h-entry with u-in-reply-to + p-rsvp, no schema.org type")
    func rsvpDescriptor() {
        let rsvp = try! #require(ContentTypeRegistry().descriptor(id: "rsvp"))
        #expect(rsvp.displayName == "RSVP")
        #expect(rsvp.collection == "rsvps")
        #expect(rsvp.projections.microformat == "h-entry")
        #expect(rsvp.projections.schemaType == nil)

        let inReplyTo = try! #require(rsvp.fields.first { $0.name == "inReplyTo" })
        #expect(inReplyTo.kind == .url)
        #expect(inReplyTo.required)
        #expect(rsvp.projections.microformatProperties["inReplyTo"] == "u-in-reply-to")

        let status = try! #require(rsvp.fields.first { $0.name == "rsvp" })
        #expect(status.kind == .enum(cases: ["yes", "no", "maybe", "interested"]))
        #expect(status.required)
        #expect(rsvp.projections.microformatProperties["rsvp"] == "p-rsvp")

        #expect(rsvp.fields.first?.name == "lang")
        #expect(rsvp.fields.last?.name == "draft")
        #expect(rsvp.titleField == nil)   // identified by inReplyTo, like reply/like (#916)
        #expect(rsvp.requiredURLFields.map(\.name) == ["inReplyTo"])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: FAIL — `descriptor(id: "rsvp")` is `nil` (`#require` throws).

- [ ] **Step 3: Add the `rsvp` descriptor**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, change `personalTypes` (line 297) to include it:

```swift
    static let personalTypes: [ContentTypeDescriptor] = [note, article, photo, album, bookmark, reply, like, rsvp, checkin, repost]
```

(`checkin`/`repost` are added by Tasks 4/5 — for this task alone, temporarily write `[..., like, rsvp]`, and widen the line again in Task 4's Step 3 and Task 5's Step 3. Do not add all three now; each task's own step re-states the exact line so the tasks stay independently executable in any order after Task 1/2.)

Add the descriptor itself right after `like` (after line 467, before the `// MARK: Site identity` comment):

```swift
    /// A response to an `h-event` recording attendance intent (yes/no/maybe/interested) — the
    /// IndieWeb RSVP post type (indieweb.org/rsvp). `inReplyTo` names the event being RSVP'd to,
    /// the same `u-in-reply-to` shape `reply` already uses; `rsvp` carries the closed-vocabulary
    /// status. No schema.org projection, matching `reply`/`like` — a terse interaction post, not
    /// structured content (#1598).
    static let rsvp = ContentTypeDescriptor(
        id: "rsvp",
        displayName: "RSVP",
        storage: .collection("rsvps"),
        fields: [
            ContentTypeField("lang", .language),
            ContentTypeField("inReplyTo", .url, required: true),
            ContentTypeField("rsvp", .enum(cases: ["yes", "no", "maybe", "interested"]), required: true),
            ContentTypeField("body", .markdown),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "inReplyTo": "u-in-reply-to",
                "rsvp": "p-rsvp",
                "body": "e-content",
                "publishDate": "dt-published",
            ],
            schemaType: nil
        )
    )
```

- [ ] **Step 4: Run the registry test to verify it passes; fix the tests it now breaks**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: the new `rsvpDescriptor` test passes; `personalTypeOrder`, `collectionBackedIDs`, `entryCollectionDescriptorsHaveLang`, and `postFamilyHasDraft` now FAIL (they enumerate exact id lists).

Update `personalTypeOrder()` (line 179-183):

```swift
    @Test("personalTypes include album, like, and rsvp in canonical order")
    func personalTypeOrder() {
        #expect(ContentTypeRegistry.personalTypes.map(\.id)
            == ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp"])
    }
```

(This assertion is intentionally re-tightened again in Task 4 and Task 5 as `checkin`/`repost` join the list — see those tasks' Step 4.)

Update `collectionBackedIDs()` (line 315-321):

```swift
    @Test("collectionBackedTypeIDs lists exactly the .collection-stored built-ins, in order")
    func collectionBackedIDs() {
        #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
            "note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp",
            "announcement", "event", "review", "member", "blogroll",
        ])
    }
```

Update `entryCollectionDescriptorsHaveLang()` (line 425-437) — add `"rsvp"` to `idsExpectingLang`:

```swift
        let idsExpectingLang = ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "announcement", "event", "review"]
```

Update `postFamilyHasDraft()` (line 273-283) — add `"rsvp"` to the loop's id list:

```swift
        for id in ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp"] {
```

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: PASS, all tests green.

- [ ] **Step 5: Add the `ContentTypeAppEnum` case**

In `Sources/AnglesiteIntents/ContentTypeAppEnum.swift`, add a case right after `.like` (after line 27, before the `// Small-business types` comment):

```swift
    /// A response to an `h-event` recording attendance intent (`u-in-reply-to` + `p-rsvp`).
    case rsvp
```

Add its display representation in `caseDisplayRepresentations` (line 52-57):

```swift
        .bookmark: "Bookmark", .reply: "Reply", .like: "Like", .rsvp: "RSVP",
```

- [ ] **Step 6: Run the drift-guard intents test**

Run: `scripts/swift-test.sh --filter ContentTypeAppEnumTests`
Expected: PASS — `ContentTypeAppEnum.allCases.map(\.rawValue) == ContentTypeRegistry.default.collectionBackedTypeIDs` now holds because both sides gained `"rsvp"` in the same position.

- [ ] **Step 7: Add the `rsvps` collection to `content.config.ts`**

In `Resources/Template/src/content.config.ts`, insert right after the `likes` collection (after line 107, before `const announcements`):

```ts
const rsvps = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/rsvps" }),
  schema: z.object({
    ...socialFields,
    lang: z.string().optional(),
    inReplyTo: z.string().url(),
    rsvp: z.enum(["yes", "no", "maybe", "interested"]),
    body: z.string().optional(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }).strict(),
});
```

Update the `collections` export (line 165) to include it, right after `likes`:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, rsvps, announcements, events, reviews, members, blogroll };
```

- [ ] **Step 8: Verify the block matches the registry via `ContentConfigDriftTests` (no new test code needed — it's generic)**

Run: `scripts/swift-test.sh --filter ContentConfigDriftTests`
Expected: PASS. `noOrphanCollections` and `configMatchesRegistry` iterate every collection-backed built-in automatically — `rsvps` is checked for free once the registry descriptor (Step 3) and the `content.config.ts` block (Step 7) both exist. If this fails, the most likely cause is a whitespace/quoting mismatch between the hand-written block and `schemaLines`' canonical rendering (`field: expr,` at 4-space indent, `required ? zod : "\(zod).optional()"`) — compare byte-for-byte against `Self.canonicalBlock` in `ContentConfigDriftTests.swift` rather than guessing.

- [ ] **Step 9: Add `rsvps` to `HENTRY_COLLECTIONS`**

In `Resources/Template/src/lib/collections.ts`, line 7-10:

```ts
export const HENTRY_COLLECTIONS = [
  "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "rsvps", "announcements",
] as const;
```

(`ENTRY_COLLECTIONS` on line 14-16 spreads `HENTRY_COLLECTIONS`, so it picks this up automatically — no separate edit needed there.)

- [ ] **Step 10: Render RSVP in `Hentry.astro`**

In `Resources/Template/src/layouts/Hentry.astro`, extend `HentryFields` (line 24-38) — add after `likeOf?: string;` (line 34):

```ts
  likeOf?: string;
  rsvp?: string;
```

Add the render branch right after the `likeOf` branch (after line 96, before the `{(d.summary ?? d.caption) &&` line):

```astro
    {d.rsvp && <data class="p-rsvp" value={d.rsvp}>RSVP: {d.rsvp.charAt(0).toUpperCase() + d.rsvp.slice(1)}</data>}
```

- [ ] **Step 11: Flip the `rsvp` guard in `post-type-discovery.ts`**

In `Resources/Template/worker/post-type-discovery.ts`, change the module doc comment (line 7-9) to drop `rsvp` from the unsupported list:

```ts
 * `discoverCollection` returns `null` for any type this bridge doesn't support yet (an
 * unrecognized `h-*` type, `repost-of`, `checkin`, `video`) — the caller must fall back
 * to `@dwk/micropub`'s own default flat-URL policy rather than guessing a collection.
```

Change line 46 from `if (hasProperty(mf2, "rsvp")) return null;` to:

```ts
  if (hasProperty(mf2, "rsvp")) return "rsvps";
```

(Leave it in the same position — before `bookmark-of`/`like-of`/`in-reply-to` — so RSVP+in-reply-to still classifies as `rsvps`, not `replies`, per the existing comment two lines above.)

- [ ] **Step 12: Update `post-type-discovery.test.ts`**

In `Resources/Template/worker/post-type-discovery.test.ts`, change the `"rsvp returns null"` test (line 93-95) to:

```ts
  test("rsvp maps to rsvps", () => {
    expect(discoverCollection(mf2("h-entry", { rsvp: ["yes"] }))).toBe("rsvps");
  });
```

Change the RSVP+in-reply-to priority test (line 97-102):

```ts
  test("an RSVP (rsvp + in-reply-to together — the standard RSVP shape) maps to rsvps, not replies", () => {
    expect(discoverCollection(mf2("h-entry", {
      "in-reply-to": ["https://example.com/event"],
      rsvp: ["yes"],
    }))).toBe("rsvps");
  });
```

Run: `cd Resources/Template && npm run test:worker`
Expected: PASS.

- [ ] **Step 13: Add `rsvps` to `feeds.ts`**

In `Resources/Template/src/lib/feeds.ts`, `FEED_COLLECTIONS` (line 61-70), insert after `likes`:

```ts
  likes: { title: "Likes", dateField: "publishDate", deriveTitle: () => undefined },
  rsvps: {
    title: "RSVPs",
    dateField: "publishDate",
    deriveTitle: (e) => (typeof e.data.rsvp === "string" ? `RSVP: ${e.data.rsvp}` : undefined),
  },
```

Extend `interactionContentFallback` (line 120-132) with an `rsvps` branch, changed to a nested structure since there are now more than 3 cases — replace lines 121-128 with:

```ts
  const targetUrl =
    collection === "likes"
      ? data.likeOf
      : collection === "replies"
        ? data.inReplyTo
        : collection === "bookmarks"
          ? data.bookmarkOf
          : collection === "rsvps"
            ? data.inReplyTo
            : undefined;
```

- [ ] **Step 14: Write the failing `feeds.test.ts` tests**

In `Resources/Template/src/lib/feeds.test.ts`, update the collections-count test (line 24-29):

```ts
test("config covers all nine collections", () => {
  assert.deepEqual(
    Object.keys(FEED_COLLECTIONS).sort(),
    ["albums", "articles", "blog", "bookmarks", "likes", "notes", "photos", "replies", "rsvps"],
  );
});
```

(This list grows again to eleven entries in Task 4/5's equivalent step — re-stated there.)

Add a new test after `"toFeedItem falls back to an escaped anchor to inReplyTo when the reply has no body"` (after line 429):

```ts
test("toFeedItem derives a title from the rsvp status and falls back to an anchor to inReplyTo when empty", () => {
  const rsvp = toFeedItem(
    "rsvps",
    entry("rsvps", { inReplyTo: "https://example.com/event", rsvp: "yes", publishDate: "2026-01-02" }, ""),
    SITE,
    "",
  );
  assert.equal(rsvp.title, "RSVP: yes");
  assert.equal(
    rsvp.contentHtml,
    `<a href="https://example.com/event">https://example.com/event</a>`,
  );
});
```

- [ ] **Step 15: Run the feed tests**

Run: `cd Resources/Template && npm test`
Expected: PASS.

- [ ] **Step 16: Full-suite verification**

Run: `scripts/swift-test.sh` (full Swift suite — `Resources/Template/` changed, so per the Global Constraints this is required, not just the filtered runs above)
Run: `cd Resources/Template && npm run test:worker && npm test`
Expected: both PASS.

- [ ] **Step 17: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Sources/AnglesiteIntents/ContentTypeAppEnum.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift Resources/Template/src/content.config.ts Resources/Template/src/lib/collections.ts Resources/Template/src/layouts/Hentry.astro Resources/Template/worker/post-type-discovery.ts Resources/Template/worker/post-type-discovery.test.ts Resources/Template/src/lib/feeds.ts Resources/Template/src/lib/feeds.test.ts
git commit -m "$(cat <<'EOF'
feat(#1598): add RSVP as a publishable post type

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Check-in content type

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift:297` (`personalTypes`, widen again), insert descriptor after `rsvp`
- Modify: `Sources/AnglesiteCore/MicropubContentSync.swift:118-126` (nested-h-card fallback for `location`)
- Modify: `Sources/AnglesiteIntents/ContentTypeAppEnum.swift` (new case, display representation)
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, `Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift`
- Modify: `Resources/Template/src/content.config.ts`, `Resources/Template/src/lib/collections.ts`
- Modify: `Resources/Template/src/layouts/Hentry.astro`
- Modify: `Resources/Template/worker/post-type-discovery.ts`
- Test: `Resources/Template/worker/post-type-discovery.test.ts`
- Modify: `Resources/Template/src/lib/feeds.ts`
- Test: `Resources/Template/src/lib/feeds.test.ts`

**Interfaces:**
- Consumes: Task 1's `.enum` plumbing is not used by check-in (its fields are `.string`/`.url`/`.markdown`) — check-in only needs Task 1's Kind-switch exhaustiveness to already be settled, which it is.
- Produces: registry id `"checkin"`, collection `"checkins"`, mf2 `h-entry` with `p-location` + optional `u-in-reply-to` (venue).
- Real-world Micropub checkin clients nest the venue as a whole `h-card` object under the **`checkin`** mf2 property (`checkin: [{type: ["h-card"], properties: {name: [...]}}]`), not a flat `location` string — confirmed by `post-type-discovery.test.ts`'s existing checkin fixture. `MicropubContentSync`'s `location` field is mapped to raw property `"location"` (matching this repo's naming convention for the *outbound*/composer-authored shape), so an *inbound*, externally-created checkin needs a fallback that reads the sibling `"checkin"` property and unwraps its nested `name` — mirroring the existing `itemReviewed`/`nestedItemName` precedent exactly. Without this fallback, `values(for:)` would return `nil` for every externally-created checkin (a required field with no resolvable value fails the whole post — see `MicropubContentSync.swift:203`), silently dropping it from sync.

- [ ] **Step 1: Write the failing registry test**

Add to `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, right after the new `rsvpDescriptor()` test:

```swift
    @Test("checkin is an h-entry with required p-location and an optional venue u-in-reply-to")
    func checkinDescriptor() {
        let checkin = try! #require(ContentTypeRegistry().descriptor(id: "checkin"))
        #expect(checkin.displayName == "Check-in")
        #expect(checkin.collection == "checkins")
        #expect(checkin.projections.microformat == "h-entry")
        #expect(checkin.projections.schemaType == nil)

        let location = try! #require(checkin.fields.first { $0.name == "location" })
        #expect(location.kind == .string)
        #expect(location.required)
        #expect(checkin.projections.microformatProperties["location"] == "p-location")

        let venueUrl = try! #require(checkin.fields.first { $0.name == "venueUrl" })
        #expect(venueUrl.kind == .url)
        #expect(!venueUrl.required)
        #expect(checkin.projections.microformatProperties["venueUrl"] == "u-in-reply-to")

        #expect(checkin.fields.first?.name == "lang")
        #expect(checkin.fields.last?.name == "draft")
        #expect(checkin.titleField == nil)
        // venueUrl is optional, so it must NOT appear in requiredURLFields (#916 contract).
        #expect(checkin.requiredURLFields.isEmpty)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: FAIL (`descriptor(id: "checkin")` is `nil`).

- [ ] **Step 3: Add the `checkin` descriptor**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, widen `personalTypes` (line 297) again:

```swift
    static let personalTypes: [ContentTypeDescriptor] = [note, article, photo, album, bookmark, reply, like, rsvp, checkin, repost]
```

Add the descriptor right after `rsvp` (from Task 3):

```swift
    /// A record of physical presence at a place — the IndieWeb check-in post type
    /// (indieweb.org/checkin), Foursquare/Swarm-style. `location` is the venue name as plain
    /// text; `venueUrl` is an optional permalink to the venue (rendered `u-in-reply-to`, the same
    /// mf2 property `reply`/`rsvp` use for their own targets — mf2 has no dedicated "venue link"
    /// property). No schema.org projection, matching `reply`/`like`/`rsvp` (#1598).
    static let checkin = ContentTypeDescriptor(
        id: "checkin",
        displayName: "Check-in",
        storage: .collection("checkins"),
        fields: [
            ContentTypeField("lang", .language),
            ContentTypeField("location", .string, required: true),
            ContentTypeField("venueUrl", .url),
            ContentTypeField("body", .markdown),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "location": "p-location",
                "venueUrl": "u-in-reply-to",
                "body": "e-content",
                "publishDate": "dt-published",
            ],
            schemaType: nil
        )
    )
```

- [ ] **Step 4: Run the registry test to verify it passes; fix the tests it now breaks**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`

Update `personalTypeOrder()`:

```swift
    @Test("personalTypes include album, like, rsvp, and checkin in canonical order")
    func personalTypeOrder() {
        #expect(ContentTypeRegistry.personalTypes.map(\.id)
            == ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin"])
    }
```

Update `collectionBackedIDs()`:

```swift
        #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
            "note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin",
            "announcement", "event", "review", "member", "blogroll",
        ])
```

Update `entryCollectionDescriptorsHaveLang()` — add `"checkin"`:

```swift
        let idsExpectingLang = ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin", "announcement", "event", "review"]
```

Update `postFamilyHasDraft()` — add `"checkin"`:

```swift
        for id in ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin"] {
```

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: PASS.

- [ ] **Step 5: Write the failing nested-h-card fallback test**

Add to `Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift`, right after the existing `"values resolves itemReviewed from a nested h-item mf2 object"` test (around line 194):

```swift
    @Test("values resolves checkin's location from the nested h-card under the sibling checkin property")
    func valuesResolvesCheckinLocationFromNestedHCard() throws {
        let descriptor = try #require(ContentTypeRegistry.default.descriptor(id: "checkin"))
        let properties: [String: [JSONValue]] = [
            "checkin": [.object(["type": .array([.string("h-card")]), "properties": .object(["name": .array([.string("The Coffee Shop")])])])],
            "content": [.string("Great espresso.")],
        ]
        let values = try #require(MicropubContentSync.values(for: descriptor, properties: properties, updatedAt: 1_750_000_000, slug: "coffee"))
        #expect(values["location"] == .text("The Coffee Shop"))
    }
```

- [ ] **Step 6: Run it to verify it fails**

Run: `scripts/swift-test.sh --filter MicropubContentSyncTests`
Expected: FAIL — `values["location"]` resolves to `nil`/empty, or the whole `values(for:)` call returns `nil` (required field unresolved).

- [ ] **Step 7: Add the nested-h-card fallback**

In `Sources/AnglesiteCore/MicropubContentSync.swift`, `fieldValue(for:rawProperty:properties:)` (line 119-126), extend the existing nested-object fallback comment and logic:

```swift
        case .string, .language, .text, .url, .image, .markdown, .enum:
            let raw = values.first
            // `itemReviewed` (h-review's `item`) and check-in's `location` are conventionally
            // nested mf2 objects (h-item/h-card), not plain strings. Each reads a *different*
            // raw property than the one this field itself maps to: `itemReviewed` nests inside
            // its own mapped property, but a check-in's location nests inside the sibling
            // `checkin` property — real Micropub check-in clients send `checkin: [{h-card}]`,
            // never a flat `location` property (#1598).
            let text = plainText(from: raw)
                ?? (field.name == "itemReviewed" ? nestedItemName(from: raw) : nil)
                ?? (field.name == "location" ? nestedItemName(from: properties["checkin"]?.first) : nil)
            guard let text else { return nil }
            return .text(text)
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `scripts/swift-test.sh --filter MicropubContentSyncTests`
Expected: PASS.

- [ ] **Step 9: Add the `ContentTypeAppEnum` case**

In `Sources/AnglesiteIntents/ContentTypeAppEnum.swift`, add right after `.rsvp`:

```swift
    /// A record of physical presence at a place (`p-location`, optional venue `u-in-reply-to`).
    case checkin
```

Add its display representation:

```swift
        .bookmark: "Bookmark", .reply: "Reply", .like: "Like", .rsvp: "RSVP", .checkin: "Check-in",
```

Run: `scripts/swift-test.sh --filter ContentTypeAppEnumTests`
Expected: PASS.

- [ ] **Step 10: Add the `checkins` collection to `content.config.ts`**

In `Resources/Template/src/content.config.ts`, insert right after the `rsvps` block (added in Task 3 Step 7):

```ts
const checkins = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/checkins" }),
  schema: z.object({
    ...socialFields,
    lang: z.string().optional(),
    location: z.string(),
    venueUrl: z.string().url().optional(),
    body: z.string().optional(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }).strict(),
});
```

Update the `collections` export, right after `rsvps`:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, rsvps, checkins, announcements, events, reviews, members, blogroll };
```

- [ ] **Step 11: Verify via the generic drift guard**

Run: `scripts/swift-test.sh --filter ContentConfigDriftTests`
Expected: PASS.

- [ ] **Step 12: Add `checkins` to `HENTRY_COLLECTIONS`**

In `Resources/Template/src/lib/collections.ts`:

```ts
export const HENTRY_COLLECTIONS = [
  "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "rsvps", "checkins", "announcements",
] as const;
```

- [ ] **Step 13: Render check-in in `Hentry.astro`**

In `Resources/Template/src/layouts/Hentry.astro`, extend `HentryFields` — add after `rsvp?: string;` (from Task 3 Step 10):

```ts
  rsvp?: string;
  location?: string;
  venueUrl?: string;
```

Add render branches right after the RSVP `<data class="p-rsvp">` line:

```astro
    {d.location && <span class="p-location h-card">{d.location}</span>}
    {d.venueUrl && <a class="u-in-reply-to" href={d.venueUrl}>{d.venueUrl}</a>}
```

- [ ] **Step 14: Flip the `checkin` guard in `post-type-discovery.ts`**

Update the module doc comment (line 7-9) again, dropping `checkin`:

```ts
 * `discoverCollection` returns `null` for any type this bridge doesn't support yet (an
 * unrecognized `h-*` type, `repost-of`, `video`) — the caller must fall back to
 * `@dwk/micropub`'s own default flat-URL policy rather than guessing a collection.
```

Change the `checkin` line:

```ts
  if (hasProperty(mf2, "checkin")) return "checkins";
```

- [ ] **Step 15: Update `post-type-discovery.test.ts`**

Change the `"checkin returns null"` test:

```ts
  test("checkin maps to checkins", () => {
    expect(discoverCollection(mf2("h-entry", { checkin: [{ type: ["h-card"], properties: { name: ["Venue"] } }] }))).toBe("checkins");
  });
```

Run: `cd Resources/Template && npm run test:worker`
Expected: PASS.

- [ ] **Step 16: Add `checkins` to `feeds.ts`**

In `FEED_COLLECTIONS`, insert after `rsvps`:

```ts
  checkins: {
    title: "Check-ins",
    dateField: "publishDate",
    deriveTitle: (e) => (typeof e.data.location === "string" ? `Checked in at ${e.data.location}` : undefined),
  },
```

Extend `interactionContentFallback`'s ternary, adding a `checkins` branch reading `venueUrl` right after the `rsvps` branch:

```ts
  const targetUrl =
    collection === "likes"
      ? data.likeOf
      : collection === "replies"
        ? data.inReplyTo
        : collection === "bookmarks"
          ? data.bookmarkOf
          : collection === "rsvps"
            ? data.inReplyTo
            : collection === "checkins"
              ? data.venueUrl
              : undefined;
```

- [ ] **Step 17: Write the failing `feeds.test.ts` tests**

Update the collections-count test:

```ts
test("config covers all ten collections", () => {
  assert.deepEqual(
    Object.keys(FEED_COLLECTIONS).sort(),
    ["albums", "articles", "blog", "bookmarks", "checkins", "likes", "notes", "photos", "replies", "rsvps"],
  );
});
```

Add a new test after the RSVP feed test added in Task 3 Step 14:

```ts
test("toFeedItem derives a title from the check-in location and falls back to an anchor to venueUrl when empty", () => {
  const checkin = toFeedItem(
    "checkins",
    entry("checkins", { location: "The Coffee Shop", venueUrl: "https://example.com/venue", publishDate: "2026-01-02" }, ""),
    SITE,
    "",
  );
  assert.equal(checkin.title, "Checked in at The Coffee Shop");
  assert.equal(
    checkin.contentHtml,
    `<a href="https://example.com/venue">https://example.com/venue</a>`,
  );
});

test("toFeedItem gives a check-in with no venueUrl an empty content fallback (no natural target URL)", () => {
  const checkin = toFeedItem(
    "checkins",
    entry("checkins", { location: "The Coffee Shop", publishDate: "2026-01-02" }, ""),
    SITE,
    "",
  );
  assert.equal(checkin.contentHtml, "");
});
```

- [ ] **Step 18: Run the feed tests**

Run: `cd Resources/Template && npm test`
Expected: PASS.

- [ ] **Step 19: Full-suite verification**

Run: `scripts/swift-test.sh`
Run: `cd Resources/Template && npm run test:worker && npm test`
Expected: both PASS.

- [ ] **Step 20: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Sources/AnglesiteCore/MicropubContentSync.swift Sources/AnglesiteIntents/ContentTypeAppEnum.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift Tests/AnglesiteCoreTests/MicropubContentSyncTests.swift Resources/Template/src/content.config.ts Resources/Template/src/lib/collections.ts Resources/Template/src/layouts/Hentry.astro Resources/Template/worker/post-type-discovery.ts Resources/Template/worker/post-type-discovery.test.ts Resources/Template/src/lib/feeds.ts Resources/Template/src/lib/feeds.test.ts
git commit -m "$(cat <<'EOF'
feat(#1598): add check-in as a publishable post type

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Repost content type

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift:297` (`personalTypes`, final widening), insert descriptor after `checkin`
- Modify: `Sources/AnglesiteIntents/ContentTypeAppEnum.swift` (new case, display representation)
- Test: `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, `Tests/AnglesiteCoreTests/SocialPublishPlanTests.swift` (confirmation only, no production code change)
- Modify: `Resources/Template/src/content.config.ts`, `Resources/Template/src/lib/collections.ts`
- Modify: `Resources/Template/src/layouts/Hentry.astro`
- Modify: `Resources/Template/worker/post-type-discovery.ts`
- Test: `Resources/Template/worker/post-type-discovery.test.ts`
- Modify: `Resources/Template/src/lib/feeds.ts`
- Test: `Resources/Template/src/lib/feeds.test.ts`

**Interfaces:**
- Consumes: nothing new from Tasks 1-2 (repost's fields are all `.url`/`.markdown`, already-plumbed kinds).
- Produces: registry id `"repost"`, collection `"reposts"`, mf2 `h-entry` with `u-repost-of`. POSSE eligibility needs **zero** production-code changes — confirmed by reading `Sources/AnglesiteCore/SocialPublishPlan.swift:150`, whose `webmentionTargets` key list already includes `"repostOf"` (a dangling hook with no descriptor to feed it until now) and whose `excludedCollections` (line 77) is `["blogroll"]` only. This task's Step 5 is a confirming test, not new plumbing.

- [ ] **Step 1: Write the failing registry test**

Add to `Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift`, right after `checkinDescriptor()`:

```swift
    @Test("repost is an h-entry with u-repost-of and no schema.org type")
    func repostDescriptor() {
        let repost = try! #require(ContentTypeRegistry().descriptor(id: "repost"))
        #expect(repost.displayName == "Repost")
        #expect(repost.collection == "reposts")
        #expect(repost.projections.microformat == "h-entry")
        #expect(repost.projections.schemaType == nil)

        let repostOf = try! #require(repost.fields.first { $0.name == "repostOf" })
        #expect(repostOf.kind == .url)
        #expect(repostOf.required)
        #expect(repost.projections.microformatProperties["repostOf"] == "u-repost-of")

        #expect(repost.fields.first?.name == "lang")
        #expect(repost.fields.last?.name == "draft")
        #expect(repost.titleField == nil)   // identified by repostOf, like reply/like/rsvp (#916)
        #expect(repost.requiredURLFields.map(\.name) == ["repostOf"])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: FAIL.

- [ ] **Step 3: Add the `repost` descriptor**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, `personalTypes` (line 297) reaches its final form:

```swift
    static let personalTypes: [ContentTypeDescriptor] = [note, article, photo, album, bookmark, reply, like, rsvp, checkin, repost]
```

(This is the same line Task 3/4 already wrote — if executed in order, no further edit is needed here; if `repost` is implemented before `rsvp`/`checkin` exist yet, adjust this line to whatever combination of the three is present so far.)

Add the descriptor right after `checkin`:

```swift
    /// A share of someone else's post, with optional commentary — the IndieWeb repost post type
    /// (indieweb.org/repost). `repostOf` names the reposted entry's URL. No schema.org
    /// projection, matching `reply`/`like`/`rsvp`/`checkin` (#1598). POSSE-eligible via the
    /// existing frontmatter-driven `SocialPublishPlan` pipeline — no new eligibility code needed;
    /// `webmentionTargets` already reads a `repostOf` frontmatter key (a dangling hook from
    /// earlier scaffolding), this descriptor is what finally makes it reachable.
    static let repost = ContentTypeDescriptor(
        id: "repost",
        displayName: "Repost",
        storage: .collection("reposts"),
        fields: [
            ContentTypeField("lang", .language),
            ContentTypeField("repostOf", .url, required: true),
            ContentTypeField("body", .markdown),
            ContentTypeField("publishDate", .datetime, required: true),
            ContentTypeField("draft", .bool),
        ],
        projections: ContentTypeProjections(
            microformat: "h-entry",
            microformatProperties: [
                "repostOf": "u-repost-of",
                "body": "e-content",
                "publishDate": "dt-published",
            ],
            schemaType: nil
        )
    )
```

- [ ] **Step 4: Run the registry test to verify it passes; fix the tests it now breaks**

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`

Update `personalTypeOrder()` to its final form:

```swift
    @Test("personalTypes include album, like, rsvp, checkin, and repost in canonical order")
    func personalTypeOrder() {
        #expect(ContentTypeRegistry.personalTypes.map(\.id)
            == ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin", "repost"])
    }
```

Update `collectionBackedIDs()` to its final form:

```swift
        #expect(ContentTypeRegistry.default.collectionBackedTypeIDs == [
            "note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin", "repost",
            "announcement", "event", "review", "member", "blogroll",
        ])
```

Update `entryCollectionDescriptorsHaveLang()` — add `"repost"`:

```swift
        let idsExpectingLang = ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin", "repost", "announcement", "event", "review"]
```

Update `postFamilyHasDraft()` — add `"repost"`:

```swift
        for id in ["note", "article", "photo", "album", "bookmark", "reply", "like", "rsvp", "checkin", "repost"] {
```

Run: `scripts/swift-test.sh --filter ContentTypeRegistryTests`
Expected: PASS.

- [ ] **Step 5: Write a confirming `SocialPublishPlan` test — no production code change**

Add to `Tests/AnglesiteCoreTests/SocialPublishPlanTests.swift`, right after the existing `webmentionTargets()` test (after line 38), mirroring its exact `writeSiteTree`/`SocialPublishPlan.build` fixture shape:

```swift
    @Test("repostOf frontmatter produces a webmention target, closing the #1598 dangling hook")
    func repostOfProducesWebmentionTarget() throws {
        let root = try writeSiteTree(prefix: "social-plan", [
            "src/content/reposts/example.md": """
            ---
            slug: reposting-that
            repostOf: "https://example.com/original"
            publishDate: 2026-06-29
            ---
            """
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try SocialPublishPlan.build(
            projectRoot: root,
            siteBase: URL(string: "https://mysite.test")!,
            referenceDate: referenceDate
        )

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].sourceFile == "src/content/reposts/example.md")
        #expect(plan.entries[0].webmentionTargets.map(\.absoluteString) == [
            "https://example.com/original",
        ])
    }
```

Run: `scripts/swift-test.sh --filter SocialPublishPlanTests`
Expected: PASS, no production code touched by this step (it was already correct — this test only proves it).

- [ ] **Step 6: Add the `ContentTypeAppEnum` case**

In `Sources/AnglesiteIntents/ContentTypeAppEnum.swift`, add right after `.checkin`:

```swift
    /// A share of someone else's post, with optional commentary (`u-repost-of`).
    case repost
```

Add its display representation:

```swift
        .bookmark: "Bookmark", .reply: "Reply", .like: "Like", .rsvp: "RSVP", .checkin: "Check-in", .repost: "Repost",
```

Run: `scripts/swift-test.sh --filter ContentTypeAppEnumTests`
Expected: PASS.

- [ ] **Step 7: Add the `reposts` collection to `content.config.ts`**

Insert right after `checkins`:

```ts
const reposts = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/reposts" }),
  schema: z.object({
    ...socialFields,
    lang: z.string().optional(),
    repostOf: z.string().url(),
    body: z.string().optional(),
    publishDate: z.coerce.date(),
    draft: z.boolean().default(false),
  }).strict(),
});
```

Update the `collections` export to its final form:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, rsvps, checkins, reposts, announcements, events, reviews, members, blogroll };
```

- [ ] **Step 8: Verify via the generic drift guard**

Run: `scripts/swift-test.sh --filter ContentConfigDriftTests`
Expected: PASS.

- [ ] **Step 9: Add `reposts` to `HENTRY_COLLECTIONS`**

Final form:

```ts
export const HENTRY_COLLECTIONS = [
  "notes", "articles", "photos", "albums",
  "bookmarks", "replies", "likes", "rsvps", "checkins", "reposts", "announcements",
] as const;
```

- [ ] **Step 10: Render repost in `Hentry.astro`**

Extend `HentryFields` — add after `venueUrl?: string;`:

```ts
  venueUrl?: string;
  repostOf?: string;
```

In the script section, extend the existing `cited()`-lookup block (right after `const likeCite = cited(d.likeOf);`):

```ts
const likeCite = cited(d.likeOf);
const repostCite = cited(d.repostOf);
```

Add the render branch right after the `likeOf` branch (mirroring its exact shape):

```astro
    {d.repostOf && (repostCite
      ? <EmbedCard snapshot={repostCite} citeClass="u-repost-of" inlineVideo={inlineVideo} />
      : <a class="u-repost-of" href={d.repostOf}>Reposted this</a>)}
```

- [ ] **Step 11: Flip the `repost-of` guard in `post-type-discovery.ts`**

Update the module doc comment to its final form (drop `repost-of`):

```ts
 * `discoverCollection` returns `null` for any type this bridge doesn't support yet (an
 * unrecognized `h-*` type, or `video`) — the caller must fall back to `@dwk/micropub`'s own
 * default flat-URL policy rather than guessing a collection.
```

Change:

```ts
  if (hasProperty(mf2, "repost-of")) return "reposts";
```

- [ ] **Step 12: Update `post-type-discovery.test.ts`**

Change the `"repost-of returns null"` test:

```ts
  test("repost-of maps to reposts", () => {
    expect(discoverCollection(mf2("h-entry", { "repost-of": ["https://example.com/post"] }))).toBe("reposts");
  });
```

Run: `cd Resources/Template && npm run test:worker`
Expected: PASS.

- [ ] **Step 13: Add `reposts` to `feeds.ts`**

In `FEED_COLLECTIONS`, insert after `checkins`:

```ts
  reposts: { title: "Reposts", dateField: "publishDate", deriveTitle: () => undefined },
```

(No derived title — reposts have no `title`/`name` field, matching `likes`/`replies`/`notes`.)

Extend `interactionContentFallback`'s ternary to its final form, adding `reposts` after `checkins`:

```ts
  const targetUrl =
    collection === "likes"
      ? data.likeOf
      : collection === "replies"
        ? data.inReplyTo
        : collection === "bookmarks"
          ? data.bookmarkOf
          : collection === "rsvps"
            ? data.inReplyTo
            : collection === "checkins"
              ? data.venueUrl
              : collection === "reposts"
                ? data.repostOf
                : undefined;
```

Update the `FeedItem.title` doc comment at the top of the file (line 6-10) to add `reposts` to the title-less-collections list:

```ts
export interface FeedItem {
  /** Absent for collections whose items have no natural title (notes, replies, likes, photos,
   * reposts, and bookmarks without an explicit title) — a synthesized title (excerpt/"Re: host"/etc.) is
   * not a real title, so we omit the field rather than fake one. */
  title?: string;
```

- [ ] **Step 14: Write the failing `feeds.test.ts` tests**

Update the collections-count test to its final form:

```ts
test("config covers all eleven collections", () => {
  assert.deepEqual(
    Object.keys(FEED_COLLECTIONS).sort(),
    ["albums", "articles", "blog", "bookmarks", "checkins", "likes", "notes", "photos", "replies", "reposts", "rsvps"],
  );
});
```

Add a new test after the check-in feed tests added in Task 4 Step 17:

```ts
test("toFeedItem leaves a repost title-less and falls back to an anchor to repostOf when empty", () => {
  const repost = toFeedItem(
    "reposts",
    entry("reposts", { repostOf: "https://example.com/original", publishDate: "2026-01-02" }, ""),
    SITE,
    "",
  );
  assert.equal(repost.title, undefined);
  assert.equal(
    repost.contentHtml,
    `<a href="https://example.com/original">https://example.com/original</a>`,
  );
});
```

- [ ] **Step 15: Run the feed tests**

Run: `cd Resources/Template && npm test`
Expected: PASS.

- [ ] **Step 16: Full-suite verification (whole feature)**

Run: `scripts/swift-test.sh` (full suite)
Run: `cd Resources/Template && npm run test:worker && npm test`
Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: all PASS / BUILD SUCCEEDED.

- [ ] **Step 17: Manual smoke test**

Per `docs/testing-macos-app.md`: launch the built app, open (or create) a test site, use **File ▸ New Collection Entry…**, confirm RSVP/Check-in/Repost appear in the Type picker, create one of each, verify the file lands under `Source/src/content/{rsvps,checkins,reposts}/` with valid frontmatter, and that `npm run build` (in the site's `Source/`) succeeds against the new schemas.

- [ ] **Step 18: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Sources/AnglesiteIntents/ContentTypeAppEnum.swift Tests/AnglesiteCoreTests/ContentTypeRegistryTests.swift Tests/AnglesiteCoreTests/SocialPublishPlanTests.swift Resources/Template/src/content.config.ts Resources/Template/src/lib/collections.ts Resources/Template/src/layouts/Hentry.astro Resources/Template/worker/post-type-discovery.ts Resources/Template/worker/post-type-discovery.test.ts Resources/Template/src/lib/feeds.ts Resources/Template/src/lib/feeds.test.ts
git commit -m "$(cat <<'EOF'
feat(#1598): add repost as a publishable post type

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## After all 5 tasks

Follow `superpowers:finishing-a-development-branch` to open the PR — per `CONTRIBUTING.md`, the PR body must use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary / Paired PR check / Test plan), note in **Paired PR check** that no sidecar PR is needed (confirmed: `@dwk/micropub` is a generic mf2 pass-through, and the `davidwkeith/workers` monorepo needs no change), and close with `Closes #1598`.
