# Inspector Phase 1 — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the typed content form into a Pages/Xcode-style right-hand inspector with the live preview in the center, and add title/description editing for plain frontmatter pages.

**Architecture:** A new `.inspector(isPresented:)` panel on the detail pane hosts a `PageInspectorView`, which renders either the existing typed descriptor form (#346) or a generic title/description form. Both editor models conform to a shared `InspectorEditorModel` protocol so one chrome (load/save/conflict/⌘S) wraps both. `SiteWindow`'s navigator routing is reworked: selecting a content entry navigates the preview (center) and sets the inspector context; the `.typed` main-pane editor path is removed.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing, `git` via `NativeContentOperations.processGitCommit`.

**Design spec:** [`docs/superpowers/specs/2026-06-27-inspector-phase1-design.md`](../specs/2026-06-27-inspector-phase1-design.md)

## Global Constraints

- **Apple-only frameworks** — no third-party Swift deps.
- **Toolchain:** Xcode 27+ / Swift 6.4. Core tests: `swift test --package-path .`. App build: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`. Use `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if the default `swift` is broken.
- **Worktree:** `/Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors`, branch `feat/346-typed-editors`. `cd` there before any git/build op. A fresh worktree app build needs `scripts/copy-plugin.sh` (with `ANGLESITE_PLUGIN_SRC` pointing at the real plugin checkout) and `xcodegen generate` first.
- **App-target logic is not CI-testable** (hosted `.app` won't launch on CI). All testable logic lives in `AnglesiteCore`; `AnglesiteApp` is validated by `swift build`/`xcodebuild` + manual smoke.
- **Pure Core types are I/O-free.**
- **Round-trip safety:** all metadata writes go through `FrontmatterDocument` — unknown keys + body preserved verbatim; only changed keys re-rendered.
- **Title model:** page title is the `title` frontmatter. The site-level tokenized title template is out of scope (main site settings, later). No `.astro` attribute editing.
- **Swift Testing** (`import Testing`, `@Suite`/`@Test`/`#expect`), not XCTest, for new tests.

---

## File Structure

New (AnglesiteCore — pure, tested):
- `Sources/AnglesiteCore/PageMetadataEditor.swift` — read/write title+description via `FrontmatterDocument`.

New (AnglesiteApp — build-validated):
- `Sources/AnglesiteApp/PageMetadataModel.swift` — `@Observable` buffer for a plain page's title/description.
- `Sources/AnglesiteApp/InspectorContext.swift` — `InspectorEditorModel` protocol + `InspectorContext` enum.
- `Sources/AnglesiteApp/PageInspectorView.swift` — shared inspector chrome + typed form + page form.

New (tests):
- `Tests/AnglesiteCoreTests/PageMetadataEditorTests.swift`

Modified:
- `Sources/AnglesiteApp/TypedEntryEditorModel.swift` — conform to `InspectorEditorModel`.
- `Sources/AnglesiteApp/TypedEntryEditorView.swift` — extract the form body as `TypedEntryForm` (drop the full-pane header/chrome; chrome moves to `PageInspectorView`).
- `Sources/AnglesiteApp/SiteWindow.swift` — remove `.typed` main-pane editor path; add inspector shell, routing rework, toolbar toggle.

---

## Task 1: `PageMetadataEditor` — title/description frontmatter read/write (Core)

**Files:**
- Create: `Sources/AnglesiteCore/PageMetadataEditor.swift`
- Test: `Tests/AnglesiteCoreTests/PageMetadataEditorTests.swift`

**Interfaces:**
- Consumes: `FrontmatterDocument` / `FrontmatterValue` (existing).
- Produces:
  - `public struct PageMetadata: Equatable, Sendable { public var title: String; public var description: String; public init(title: String, description: String) }`
  - `public enum PageMetadataEditor { public static func read(_ contents: String) -> PageMetadata; public static func write(_ metadata: PageMetadata, into contents: String) -> String }`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/AnglesiteCoreTests/PageMetadataEditorTests.swift
import Testing
@testable import AnglesiteCore

@Suite("PageMetadataEditor")
struct PageMetadataEditorTests {
    @Test("reads title and description from frontmatter")
    func reads() {
        let src = "---\ntitle: \"Hello\"\ndescription: \"A page\"\n---\n\nBody.\n"
        let m = PageMetadataEditor.read(src)
        #expect(m.title == "Hello")
        #expect(m.description == "A page")
    }

    @Test("missing fields default to empty")
    func defaults() {
        let m = PageMetadataEditor.read("---\ntitle: \"Only\"\n---\nB\n")
        #expect(m.title == "Only")
        #expect(m.description == "")
    }

    @Test("write changes only edited keys, preserving unknown keys and body")
    func writeChangedOnly() {
        let src = "---\ntitle: \"Old\"\ndescription: \"D\"\nweird: keep-me\n---\n\nBody.\n"
        let out = PageMetadataEditor.write(PageMetadata(title: "New", description: "D"), into: src)
        #expect(out.contains("title: \"New\""))
        #expect(out.contains("description: \"D\""))   // unchanged
        #expect(out.contains("weird: keep-me"))       // unknown key preserved
        #expect(out.hasSuffix("\n\nBody.\n"))         // body preserved
    }

    @Test("write adds missing keys")
    func writeAddsKeys() {
        let out = PageMetadataEditor.write(PageMetadata(title: "T", description: "New desc"),
                                           into: "---\ntitle: \"T\"\n---\nB\n")
        #expect(out.contains("description: \"New desc\""))
    }

    @Test("unedited round-trip is the identity")
    func identity() {
        let src = "---\ntitle: \"T\"\ndescription: \"D\"\n---\n\nBody.\n"
        let m = PageMetadataEditor.read(src)
        #expect(PageMetadataEditor.write(m, into: src) == src)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift test --package-path . --filter PageMetadataEditor 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PageMetadataEditor' in scope`.

- [ ] **Step 3: Implement `PageMetadataEditor`**

```swift
// Sources/AnglesiteCore/PageMetadataEditor.swift
import Foundation

/// A page's editable metadata. Phase 1 covers title + description; the rendered `<title>` is
/// composed from a site-level tokenized template (main site settings, out of scope here) with this
/// per-page `title` substituted.
public struct PageMetadata: Equatable, Sendable {
    public var title: String
    public var description: String
    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

/// Reads/writes `title` + `description` frontmatter for plain (non-typed) frontmatter pages.
/// Goes through `FrontmatterDocument`, so unknown keys and the body survive verbatim and only a
/// changed key is re-rendered. Pure, no I/O.
public enum PageMetadataEditor {
    public static func read(_ contents: String) -> PageMetadata {
        let doc = FrontmatterDocument.parse(contents)
        return PageMetadata(title: scalar(doc, "title"), description: scalar(doc, "description"))
    }

    public static func write(_ metadata: PageMetadata, into contents: String) -> String {
        var doc = FrontmatterDocument.parse(contents)
        let current = read(contents)
        if metadata.title != current.title { doc.set(.string(metadata.title), for: "title") }
        if metadata.description != current.description {
            doc.set(.string(metadata.description), for: "description")
        }
        return doc.serialized()
    }

    private static func scalar(_ doc: FrontmatterDocument, _ key: String) -> String {
        if case .string(let s)? = doc.value(for: key) { return s }
        return ""
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --package-path . --filter PageMetadataEditor 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteCore/PageMetadataEditor.swift Tests/AnglesiteCoreTests/PageMetadataEditorTests.swift
git commit -m "$(printf 'feat(#346): PageMetadataEditor reads/writes title+description frontmatter\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 2: `InspectorEditorModel` protocol + `PageMetadataModel` (App)

**Files:**
- Create: `Sources/AnglesiteApp/InspectorContext.swift`
- Create: `Sources/AnglesiteApp/PageMetadataModel.swift`
- Modify: `Sources/AnglesiteApp/TypedEntryEditorModel.swift` (add protocol conformance)

**Interfaces:**
- Consumes: `PageMetadataEditor`/`PageMetadata` (Task 1), `FileDocumentIO`, `NativeContentOperations.GitCommit`, `FileRef`, `TypedEntryEditorModel` (#346).
- Produces:
  - `@MainActor protocol InspectorEditorModel: AnyObject` with: `var file: FileRef { get }`, `var isDirty: Bool { get }`, `var loadError: String? { get }`, `var isLoading: Bool { get }`, `var conflictDiskContents: String? { get set }`, `func load() async`, `@discardableResult func save() async -> Bool`, `func flushBeforeLeaving() async -> Bool`, `func checkExternalChange() async`, `func keepMyChanges()`, `func reloadFromDisk() async`.
  - `enum InspectorContext: Identifiable` with `case typed(TypedEntryEditorModel)`, `case page(PageMetadataModel)`, `var model: any InspectorEditorModel`, `var id: String`.
  - `@MainActor @Observable final class PageMetadataModel` with init `(file: FileRef, sourceDirectory: URL, gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit)`, conforming to `InspectorEditorModel`, plus `func titleBinding() -> Binding<String>` and `func descriptionBinding() -> Binding<String>`.

- [ ] **Step 1: Create the protocol + context**

```swift
// Sources/AnglesiteApp/InspectorContext.swift
import Foundation
import AnglesiteCore

/// Shared surface the inspector chrome (load/save/conflict/⌘S) drives, so one chrome wraps both the
/// typed descriptor form and the plain page metadata form.
@MainActor
protocol InspectorEditorModel: AnyObject {
    var file: FileRef { get }
    var isDirty: Bool { get }
    var loadError: String? { get }
    var isLoading: Bool { get }
    var conflictDiskContents: String? { get set }
    func load() async
    @discardableResult func save() async -> Bool
    func flushBeforeLeaving() async -> Bool
    func checkExternalChange() async
    func keepMyChanges()
    func reloadFromDisk() async
}

/// What the right-hand inspector is editing for the current selection.
enum InspectorContext: Identifiable {
    case typed(TypedEntryEditorModel)
    case page(PageMetadataModel)

    var model: any InspectorEditorModel {
        switch self {
        case .typed(let m): m
        case .page(let m): m
        }
    }
    var id: String { model.file.id }
}
```

- [ ] **Step 2: Conform `TypedEntryEditorModel` to the protocol**

`TypedEntryEditorModel` already has every required member (from #346). Add the conformance. In `Sources/AnglesiteApp/TypedEntryEditorModel.swift`, change the class declaration line:

```swift
final class TypedEntryEditorModel {
```
to:
```swift
final class TypedEntryEditorModel: InspectorEditorModel {
```

- [ ] **Step 3: Implement `PageMetadataModel`**

```swift
// Sources/AnglesiteApp/PageMetadataModel.swift
import Foundation
import SwiftUI
import Observation
import AnglesiteCore

/// Editor state for a plain (non-typed) page's title + description. Parallels
/// `TypedEntryEditorModel`: loads/saves through `FileDocumentIO`, writes via `PageMetadataEditor`
/// (round-trip-safe), and commits each save. All disk IO runs off the main actor.
@MainActor
@Observable
final class PageMetadataModel: InspectorEditorModel {
    let file: FileRef
    private let sourceDirectory: URL
    private let gitCommit: NativeContentOperations.GitCommit

    var metadata = PageMetadata(title: "", description: "")
    private var savedMetadata = PageMetadata(title: "", description: "")
    private var contents = ""
    private var lastModified: Date?
    private(set) var loadError: String?
    private(set) var isLoading = false
    var conflictDiskContents: String?

    var isDirty: Bool { metadata != savedMetadata && loadError == nil && !isLoading }

    init(file: FileRef,
         sourceDirectory: URL,
         gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit) {
        self.file = file
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
        let newContents = PageMetadataEditor.write(metadata, into: contents)
        let url = file.url
        do {
            let mtime = try await Task.detached(priority: .userInitiated) {
                try FileDocumentIO.save(newContents, to: url)
            }.value
            lastModified = mtime
            contents = newContents
            savedMetadata = metadata
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

    func titleBinding() -> Binding<String> {
        Binding(get: { self.metadata.title }, set: { self.metadata.title = $0 })
    }
    func descriptionBinding() -> Binding<String> {
        Binding(get: { self.metadata.description }, set: { self.metadata.description = $0 })
    }

    private func adopt(_ text: String) {
        contents = text
        let read = PageMetadataEditor.read(text)
        metadata = read
        savedMetadata = read
    }

    private func commit() async {
        let rel = relativePath(of: file.url, under: sourceDirectory)
        let slug = file.url.deletingPathExtension().lastPathComponent
        _ = await gitCommit(sourceDirectory, rel, "anglesite: edit page \(slug)")
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

- [ ] **Step 4: Build to verify it compiles**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift build --package-path . 2>&1 | tail -20`
Expected: builds clean. (Fix any protocol-conformance mismatch on `TypedEntryEditorModel` — every member already exists, so conformance should be satisfied without new code.)

- [ ] **Step 5: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/InspectorContext.swift Sources/AnglesiteApp/PageMetadataModel.swift Sources/AnglesiteApp/TypedEntryEditorModel.swift
git commit -m "$(printf 'feat(#346): InspectorEditorModel protocol + PageMetadataModel\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: `PageInspectorView` — shared chrome + both forms (App)

**Files:**
- Create: `Sources/AnglesiteApp/PageInspectorView.swift`
- Modify: `Sources/AnglesiteApp/TypedEntryEditorView.swift` (extract `TypedEntryForm`, drop the full-pane chrome)

**Interfaces:**
- Consumes: `InspectorContext`/`InspectorEditorModel` (Task 2), `PageMetadataModel` (Task 2), `TypedEntryEditorModel` + the `control(for:)`/`StringListEditor` form internals (#346).
- Produces: `struct PageInspectorView: View` taking `let context: InspectorContext`; `struct TypedEntryForm: View` taking `@Bindable var model: TypedEntryEditorModel`.

- [ ] **Step 1: Extract the typed form body in `TypedEntryEditorView.swift`**

Replace the whole file `Sources/AnglesiteApp/TypedEntryEditorView.swift` with the form extracted as `TypedEntryForm` (the header/`.task`/alert/⌘S chrome is removed — `PageInspectorView` supplies it). Keep `control(for:)`, `chooseFile`, and `StringListEditor` unchanged:

```swift
// Sources/AnglesiteApp/TypedEntryEditorView.swift
import SwiftUI
import AnglesiteCore

/// The schema-driven `Form` body for a typed content entry — one control per field `Kind`, ordered
/// by the descriptor. Hosted inside `PageInspectorView`, which supplies the load/save/conflict
/// chrome. (Previously a full-pane editor; the chrome moved to the inspector.)
struct TypedEntryForm: View {
    @Bindable var model: TypedEntryEditorModel

    var body: some View {
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
                TextField("", text: model.textBinding(field.name), axis: .vertical).lineLimit(2...6)
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
}

/// A minimal add/remove list editor for `stringArray` / `imageArray` fields (tags, hours, album
/// images). Rows carry stable UUID identity so deleting a row never re-binds a surviving row's
/// editor to the wrong item; `rows` mirrors the bound `items` two-way, re-syncing when `items` is
/// replaced externally (e.g. reload-from-disk).
private struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    var pickFile: Bool

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var value: String
    }
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach($rows) { $row in
                HStack {
                    TextField("", text: $row.value)
                    Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Button { rows.append(Row(value: "")) } label: { Label("Add", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                if pickFile {
                    Button("Choose…") { chooseFile() }
                }
            }
        }
        .onAppear { syncRowsFromItems() }
        .onChange(of: items) { _, new in
            if new != rows.map(\.value) { rows = new.map(Row.init(value:)) }
        }
        .onChange(of: rows) { _, new in
            let mapped = new.map(\.value)
            if mapped != items { items = mapped }
        }
    }

    private func syncRowsFromItems() {
        if items != rows.map(\.value) { rows = items.map(Row.init(value:)) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { rows.append(Row(value: url.lastPathComponent)) }
    }
}
```

- [ ] **Step 2: Create `PageInspectorView` with shared chrome**

```swift
// Sources/AnglesiteApp/PageInspectorView.swift
import SwiftUI
import AnglesiteCore

/// Right-hand inspector content for the selected page. Renders the typed descriptor form or the
/// plain title/description form, wrapped in shared chrome (header + dirty/Save, off-main load,
/// external-change conflict alert, ⌘S). Phase 1 has a single "Page" section; a tab picker for
/// selection-level editing comes in Phase 3.
struct PageInspectorView: View {
    let context: InspectorContext

    var body: some View {
        switch context {
        case .typed(let model):
            InspectorChrome(model: model) { TypedEntryForm(model: model) }
        case .page(let model):
            InspectorChrome(model: model) { PageMetadataForm(model: model) }
        }
    }
}

/// The form for a plain (non-typed) frontmatter page: title + description.
private struct PageMetadataForm: View {
    @Bindable var model: PageMetadataModel

    var body: some View {
        Form {
            TextField("Title", text: model.titleBinding())
            VStack(alignment: .leading) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextField("", text: model.descriptionBinding(), axis: .vertical).lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
    }
}

/// Shared inspector chrome around any `InspectorEditorModel`. Generic over the concrete model so the
/// form bodies keep their `@Bindable` two-way bindings.
private struct InspectorChrome<M: InspectorEditorModel & Observable, Form: View>: View {
    @Bindable var model: M
    @ViewBuilder var form: () -> Form
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
                    form()
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
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift build --package-path . 2>&1 | tail -25`
Expected: builds clean. (At this point `TypedEntryEditorView` no longer exists as a type — Task 4 removes its last `SiteWindow` reference, so the package may still reference it; if `swift build` flags `cannot find 'TypedEntryEditorView'` in `SiteWindow.swift`, that reference is removed in Task 4 — proceed; the App module fully compiles after Task 4. To keep this task self-contained, you may temporarily expect the error to be confined to `SiteWindow.swift`'s `mainPaneContent`.)

- [ ] **Step 4: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/PageInspectorView.swift Sources/AnglesiteApp/TypedEntryEditorView.swift
git commit -m "$(printf 'feat(#346): PageInspectorView — shared inspector chrome + page/typed forms\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: Wire the inspector into `SiteWindow`; remove the `.typed` main-pane path

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `InspectorContext` (Task 2), `PageInspectorView` (Task 3), `PageMetadataModel`/`TypedEntryEditorModel` (Task 2), `ContentTypeResolver` (#346), `contentGraph` (existing).

This task removes the `.typed` main-pane editor and replaces it with the inspector. Do the edits in order.

- [ ] **Step 1: Remove `.typed` from the `ActiveEditor` enum**

Replace (around line 12):
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
with:
```swift
private enum ActiveEditor {
    case text(FileEditorModel)
    case plist(PlistEditorModel)

    var file: FileRef {
        switch self {
        case .text(let model): model.file
        case .plist(let model): model.file
        }
    }
}
```

- [ ] **Step 2: Add inspector state**

After the `@State private var activeEditor: ActiveEditor?` line (around line 116), add:
```swift
    /// The right-hand inspector's current target (typed entry or plain page), or nil when the
    /// selection has no editable metadata. Set by `applyNavigatorSelection`.
    @State private var inspectorContext: InspectorContext?
    /// Inspector visibility, persisted per window. Defaults to shown (auto-open); the toolbar toggle
    /// flips it and the choice persists across selections.
    @SceneStorage("siteInspector.shown") private var inspectorShown = true
```

- [ ] **Step 3: Attach `.inspector` to the detail content**

In `siteUI(for:)`, the detail `ZStack` carries `.navigationTitle`/`.navigationSubtitle`/`.toolbar`. Add the inspector alongside them. Find (around line 240):
```swift
        .navigationTitle(site.name)
        .navigationSubtitle(preview.readyURL?.absoluteString ?? "")
        .toolbar {
```
and insert the `.inspector` modifier immediately before `.navigationTitle`:
```swift
        .inspector(isPresented: Binding(
            get: { inspectorShown && inspectorContext != nil },
            set: { inspectorShown = $0 }
        )) {
            if let inspectorContext {
                PageInspectorView(context: inspectorContext)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .navigationTitle(site.name)
```

- [ ] **Step 4: Add the toolbar toggle**

Inside the `.toolbar { … }` block, add a toggle item (place it as the first `ToolbarItem` after the opening brace, before the Backup item):
```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(inspectorContext == nil)
                .help("Show or hide the page inspector")
            }
```

- [ ] **Step 5: Remove the `.typed` main-pane render**

Replace (around line 554):
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
```
with:
```swift
        case .editor:
            if case .text(let editorModel) = activeEditor {
                MainPaneEditorView(model: editorModel)
            } else if case .plist(let plistEditorModel) = activeEditor {
                PlistEditorView(model: plistEditorModel) { title in
                    Task { await saveWebsiteTitle(title) }
                }
```

- [ ] **Step 6: Remove the `.typed` cases from `showsPaneModePicker`, `leaveCurrentEditor`, `persistEditorBufferBestEffort`**

In `showsPaneModePicker` (around line 490), replace:
```swift
        case .some(.plist), .some(.typed), .none:
            return false
```
with:
```swift
        case .some(.plist), .none:
            return false
```

In `leaveCurrentEditor` (around line 516), remove the `.typed` arm:
```swift
        case .typed(let model):
            return await model.flushBeforeLeaving()
```

In `persistEditorBufferBestEffort` (around line 543), replace:
```swift
        case .typed(let model) where model.isDirty:
            Task { await model.flushBeforeLeaving() }
        case .text, .typed, nil:
            break
```
with:
```swift
        case .text, nil:
            break
```

- [ ] **Step 7: Add inspector-flush + teardown handling**

Add a helper next to `leaveCurrentEditor` (after it, around line 526):
```swift
    /// Flush the inspector's editor before changing selection or tearing down — autosaves a dirty
    /// buffer, returns false (and the model raises its conflict alert) on an external conflict so the
    /// caller aborts the switch. Safe when no inspector is active.
    private func leaveCurrentInspector() async -> Bool {
        guard let model = inspectorContext?.model else { return true }
        return await model.flushBeforeLeaving()
    }
```
In the two teardown sites that already do `persistEditorBufferBestEffort(); activeEditor = nil; mainPaneMode = .preview` (around lines 146 and 179), add inspector teardown right after `activeEditor = nil`:
```swift
            if let model = inspectorContext?.model { Task { await model.flushBeforeLeaving() } }
            inspectorContext = nil
```

- [ ] **Step 8: Rework `applyNavigatorSelection` routing**

Replace the entire `.route`/`.file` switch body and the `typedEditorForContent` helper. Replace (around lines 666–747) the `switch target { … }` plus `typedEditorForContent(...)` with:

```swift
        switch target {
        case .route(let route):
            Task {
                guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
                // Content entry → preview in the center; its metadata in the inspector.
                activeEditor = nil
                mainPaneMode = .preview
                if route.isEmpty || route == "/" { preview.clearRoute() } else { preview.navigate(toRoute: route) }
                inspectorContext = await makeInspectorContext(forNavigatorID: id)
            }
        case .file(let file):
            if activeEditorFile?.id == file.id {
                mainPaneMode = .editor(file)   // re-show the already-open file (buffer intact)
                return
            }
            Task {
                guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
                inspectorContext = nil   // files (components/styles/metadata) have no page inspector
                switch EditorKind.resolve(for: file) {
                case .text:
                    activeEditor = .text(FileEditorModel(file: file))
                case .plist:
                    activeEditor = .plist(PlistEditorModel(
                        file: file,
                        websiteTitle: site?.name ?? file.name,
                        sourceDirectory: site?.sourceDirectory ?? file.url.deletingLastPathComponent()
                    ))
                }
                mainPaneMode = .editor(file)
            }
        }
    }

    /// Project-relative path of `url` under the site `Source/` directory, for content-type resolution.
    private func relativeProjectPath(of url: URL, under root: URL) -> String {
        let u = url.standardizedFileURL.path(percentEncoded: false)
        let r = root.standardizedFileURL.path(percentEncoded: false)
        guard u.hasPrefix(r) else { return url.lastPathComponent }
        return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description
    }

    /// Build the inspector context for a content navigator id: the typed descriptor form when the
    /// file resolves to a content type, the plain title/description form for a frontmatter-bearing
    /// markdown page, or nil (plain `.astro`/other → preview only, no inspector).
    private func makeInspectorContext(forNavigatorID id: String) async -> InspectorContext? {
        guard let source = site?.sourceDirectory else { return nil }
        let relPath: String
        let group: FileGroup
        let displayName: String
        if let page = await contentGraph.page(id: id) {
            relPath = page.filePath; group = .pages; displayName = page.title ?? page.route
        } else if let post = await contentGraph.post(id: id) {
            relPath = post.filePath; group = .posts; displayName = post.title
        } else {
            return nil
        }
        let url = source.appendingPathComponent(relPath)
        let file = FileRef(url: url, group: group, name: displayName)
        if let descriptor = ContentTypeResolver.descriptor(forRelativePath: relPath) {
            return .typed(TypedEntryEditorModel(file: file, descriptor: descriptor, sourceDirectory: source))
        }
        if isFrontmatterPage(relPath) {
            return .page(PageMetadataModel(file: file, sourceDirectory: source))
        }
        return nil   // plain .astro / other → preview only
    }

    private func isFrontmatterPage(_ relPath: String) -> Bool {
        let ext = (relPath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "mdx" || ext == "markdown"
    }
```

Note: the previous `relativeProjectPath` helper (used only by the removed `.file` typed-resolution) is retained above in case other call sites use it; if `swift build` reports it as unused, remove it.

- [ ] **Step 9: Build the app target**

Run:
```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
export ANGLESITE_PLUGIN_SRC="$(cd ../../../../anglesite 2>/dev/null && pwd)"
scripts/copy-plugin.sh 2>&1 | tail -2 || true
xcodegen generate 2>&1 | tail -2
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -25
```
Expected: **BUILD SUCCEEDED**. Fix any leftover `.typed`/`TypedEntryEditorView` reference the steps missed (grep `grep -n "\.typed\|TypedEntryEditorView" Sources/AnglesiteApp/SiteWindow.swift` should return nothing).

- [ ] **Step 10: Commit**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(printf 'feat(#346): host the editor in a right inspector; preview stays centered\n\nContent selection navigates the preview (center) and opens its metadata in\na .inspector panel (typed form or page title/description), with a toolbar\ntoggle. Removes the .typed main-pane editor path.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 5: Full verification + PR update

**Files:** none (verification).

- [ ] **Step 1: Core tests**

Run: `cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors && swift test --package-path . 2>&1 | tail -25`
Expected: all pass, including the new `PageMetadataEditor` suite and the unchanged `FrontmatterDocument`/`TypedContentEditor`/`ContentTypeResolver` suites. (Known env gap: the MCP/apply-edit e2e tests fail without `ANGLESITE_PLUGIN_PATH`/node — confirm only those fail.)

- [ ] **Step 2: App build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -derivedDataPath ./build-smoke build 2>&1 | tail -6`
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: In-app smoke**

Launch `./build-smoke/Build/Products/Debug/Anglesite.app` against a site scaffolded from the current template (a `.anglesite` package whose `Source/` is the template, with `node_modules` symlinked so the runtime starts; register it in `~/Library/Application Support/Anglesite/recents.json`). Verify:
1. Select a note → center shows the preview, the **right inspector** shows the typed form (publishDate/tags/Body). Edit a field → Save → file on disk updates + `git log -1` shows `anglesite: edit note <slug>`.
2. Select `about.md` → inspector shows the Business Profile form; `type`/`layout`/`title` keys preserved on save.
3. Select a plain markdown page (add one if the template has none) → inspector shows Title + Description.
4. Select `index.astro` → preview only, **no** inspector. Select a component → main-pane text editor, no inspector.
5. The toolbar `sidebar.right` button hides/shows the inspector; the choice persists when switching between content entries.

Record results; clean up the throwaway site + recents entry afterward.

- [ ] **Step 4: Push (updates the open PR #397)**

```bash
cd /Users/dwk/Developer/github.com/Anglesite/Anglesite-app/.claude/worktrees/346-typed-editors
rm -rf build-smoke
git push 2>&1 | tail -3
gh pr comment 397 --body "Phase 1 inspector landed: typed + page metadata now edit in a right-hand inspector with the preview centered. [smoke results …]"
```

---

## Self-Review

**Spec coverage:**
- Inspector shell via `.inspector` + toolbar toggle + remembered visibility → Task 4 (Steps 2–4). ✓
- Center = live preview on content selection → Task 4 Step 8 (`.route` navigates preview). ✓
- Typed entries via #346 core in the inspector → Tasks 2–3 (conformance + `TypedEntryForm` in `PageInspectorView`). ✓
- Plain frontmatter pages get title/description → Tasks 1–3 (`PageMetadataEditor`/`Model`/`PageMetadataForm`). ✓
- `.astro`/other → preview only, no inspector → Task 4 Step 8 (`inspectorContext` returns nil). ✓
- Components/styles keep main-pane text editor → Task 4 Step 8 (`.file` branch unchanged; `inspectorContext = nil`). ✓
- Remove `.typed` main-pane path → Task 4 Steps 1, 5, 6. ✓
- Per-edit git commit → Task 2 (`PageMetadataModel.commit`) + existing `TypedEntryEditorModel`. ✓
- Round-trip safety via `FrontmatterDocument` → Task 1. ✓
- Flush-on-leave + teardown for the inspector model → Task 4 Step 7. ✓
- Body stays in the typed form (Phase 1) → Task 3 (`TypedEntryForm` keeps the Body section). ✓
- Title-template + social cards + selection-level + `.astro` editing all out of scope → not implemented. ✓

**Placeholder scan:** No TBD/TODO. The two conditional notes (Task 3 Step 3 build-error confinement; Task 4 Step 8 `relativeProjectPath` possibly-unused) are bounded with exact grep/expected-error guidance, not open-ended work. ✓

**Type consistency:** `InspectorEditorModel` members match what `TypedEntryEditorModel` (#346) and `PageMetadataModel` (Task 2) expose; `InspectorContext.model: any InspectorEditorModel`; `PageMetadataEditor.read/write` signatures match their uses in `PageMetadataModel`; `makeInspectorContext(forNavigatorID:)`/`leaveCurrentInspector()`/`isFrontmatterPage(_:)` are defined and called consistently in Task 4; `PageInspectorView(context:)` matches the `.inspector` call site. ✓
