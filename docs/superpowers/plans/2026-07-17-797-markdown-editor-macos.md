# Markdown Editor for Post Bodies on macOS (#797) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live-styled Markdown editing for post bodies and `.md`/`.mdx` files — attribute-only styling of raw source, interactive checkboxes, Format menu (⌘B/⌘I/⌘K, headings) and Edit ▸ Find — with zero behavior change to saving/dirty-tracking/conflict handling.

**Architecture:** Adopt **swift-markdown-engine** (per the #796 survey addendum in `docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md`) behind an app-owned `MarkdownTextView` SwiftUI seam — the *only* file that imports `MarkdownEngine`. Menu commands and the find bar talk to a Foundation-only `MarkdownEditorController` that forwards to the engine over per-instance `NotificationCenter` names (the engine's `MarkdownEditorBus`); a first-responder-tracking container feeds a `MarkdownEditorFocusRegistry` so commands always target the focused editor (two editors can share one window: main pane + inspector).

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), swift-markdown-engine (Apache-2.0, TextKit 2), XcodeGen, Swift Testing.

## Global Constraints

- Substrate: `Anglesite/swift-markdown-engine` fork of `nodes-app/swift-markdown-engine` at upstream `665f7c46aa4933fdf714f558ef975067f7932421` (v0.10.0) **plus one patch** making automatic quote substitution configurable. Pinned **by revision** in both Package.swift and project.yml (SwiftGit2/STTextView policy: deliberate bumps only).
- Smart quotes must be OFF in Anglesite's editors (addendum §2); the fork patch defaults to `true` (upstream-compatible, upstreamable) and Anglesite passes `false`.
- **Only `Sources/AnglesiteApp/MarkdownTextView.swift` may `import MarkdownEngine`** (addendum §1: substrate stays swappable; call sites never import it directly).
- **View-layer swap only:** `FileEditorModel` / `TypedEntryEditorModel` load/save/dirty/conflict logic is untouched beyond adding one stored `MarkdownEditorController` property each.
- No dependencies beyond the one approved engine package. No other new packages.
- Conventional commits referencing `#797`. Commit `Sources/AnglesiteApp/Localizable.xcstrings` regenerations in the same commit as the change that adds user-visible strings (build the app target to regenerate).
- `Anglesite.xcodeproj` is generated: after any `project.yml` edit run `xcodegen generate`; never hand-edit the project.
- Worktree: `.claude/worktrees/swift-native-git-package-be2908` on branch `claude/macos-editor-dc5277`. All commands run from the worktree root.
- v1 construct set per spec §A.2: headings, bold/italic/strikethrough, inline+fenced code, links, lists, task checkboxes, blockquotes. LaTeX/wiki-links/tables-grid/image-thumbnails are out of scope (run plain-Markdown; do NOT link `MarkdownEngineCodeBlocks`/`MarkdownEngineLatex` products).

---

### Task 0: Worktree prep

**Files:** none (git/project state only)

- [ ] **Step 0.1: Rebase onto current main**

```bash
git fetch origin
git rebase origin/main
```

Expected: clean rebase (branch has no local commits yet, so this fast-forwards).

- [ ] **Step 0.2: Generate the Xcode project**

```bash
xcodegen generate
```

Expected: `Created project at …/Anglesite.xcodeproj` (gitignored; a fresh worktree has none until this runs).

- [ ] **Step 0.3: Baseline sanity test**

```bash
swift test --package-path . --filter EditorKindTests
```

Expected: PASS (3 tests). If `swift test` hangs with no output, check `pgrep -fl swift-test` for a stale SwiftPM process holding the `.build` lock and kill it.

---

### Task 1: Fork swift-markdown-engine and patch smart quotes

The addendum (§2) requires disabling smart quotes; upstream hard-enables `isAutomaticQuoteSubstitutionEnabled` in two places with no config seam. Per the addendum: "prefer upstreaming a config toggle, else carry the patch in our pin" — the patch is carried in an Anglesite org fork (same mechanism as `Anglesite/SwiftGit2`). The patch adds a field to the existing `SpellCheckingPolicy` (defaulting to `true`, so the fork is behavior-identical to upstream for other embedders and the change is upstreamable).

**Files (in the fork, not this repo):**
- Modify: `Sources/MarkdownEngine/Configuration/MarkdownEditorConfiguration.swift` (SpellCheckingPolicy, ~line 135)
- Modify: `Sources/MarkdownEngine/TextView/NativeTextViewWrapper.swift:270`
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Autocorrect.swift:65`

**Interfaces:**
- Produces: `SpellCheckingPolicy.init(continuousSpellChecking:grammarChecking:automaticSpellingCorrection:automaticQuoteSubstitution:)` with `automaticQuoteSubstitution: Bool = true`; a fork commit SHA (**FORK-SHA**) consumed by Task 2.

- [ ] **Step 1.1: Create the org fork (idempotent)**

```bash
gh repo view Anglesite/swift-markdown-engine >/dev/null 2>&1 \
  || gh repo fork nodes-app/swift-markdown-engine --org Anglesite --clone=false
```

- [ ] **Step 1.2: Clone and branch from the pinned upstream revision**

Work in the session scratchpad (a clone of upstream may already exist there — reuse it):

```bash
cd "$SCRATCHPAD/swift-markdown-engine"   # git clone https://github.com/nodes-app/swift-markdown-engine if absent
git remote add anglesite https://github.com/Anglesite/swift-markdown-engine 2>/dev/null || true
git checkout -b anglesite-pin 665f7c46aa4933fdf714f558ef975067f7932421
```

- [ ] **Step 1.3: Patch `SpellCheckingPolicy`**

In `Sources/MarkdownEngine/Configuration/MarkdownEditorConfiguration.swift`, extend the struct (keep existing doc comments; add the new field last so the init stays source-compatible):

```swift
public struct SpellCheckingPolicy: Sendable {
    /// Mirrors `NSTextView.isContinuousSpellCheckingEnabled`.
    public var continuousSpellChecking: Bool
    /// Mirrors `NSTextView.isGrammarCheckingEnabled`.
    public var grammarChecking: Bool
    /// Mirrors `NSTextView.isAutomaticSpellingCorrectionEnabled`.
    public var automaticSpellingCorrection: Bool
    /// Mirrors `NSTextView.isAutomaticQuoteSubstitutionEnabled`. Markdown sources
    /// sometimes need straight quotes throughout (frontmatter, code-adjacent prose);
    /// `true` preserves the historical always-on behavior.
    public var automaticQuoteSubstitution: Bool

    public init(
        continuousSpellChecking: Bool = true,
        grammarChecking: Bool = true,
        automaticSpellingCorrection: Bool = true,
        automaticQuoteSubstitution: Bool = true
    ) {
        self.continuousSpellChecking = continuousSpellChecking
        self.grammarChecking = grammarChecking
        self.automaticSpellingCorrection = automaticSpellingCorrection
        self.automaticQuoteSubstitution = automaticQuoteSubstitution
    }

    public static let `default` = SpellCheckingPolicy()
}
```

- [ ] **Step 1.4: Wire the two enable sites**

`Sources/MarkdownEngine/TextView/NativeTextViewWrapper.swift` line 270 — replace:

```swift
        textView.isAutomaticQuoteSubstitutionEnabled = true
```

with:

```swift
        textView.isAutomaticQuoteSubstitutionEnabled = configuration.spellChecking.automaticQuoteSubstitution
```

`Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Autocorrect.swift` line 65 — replace:

```swift
        textView.isAutomaticQuoteSubstitutionEnabled = !shouldDisableSpelling
```

with:

```swift
        textView.isAutomaticQuoteSubstitutionEnabled = shouldDisableSpelling
            ? false
            : configuration.spellChecking.automaticQuoteSubstitution
```

(`configuration` is already a stored property on the coordinator — set in `makeNSView`.)

- [ ] **Step 1.5: Run the engine's own tests**

```bash
swift test
```

Expected: PASS (upstream `MarkdownEngineTests`; the patch is attribute-plumbing only, no parser/styler behavior change).

- [ ] **Step 1.6: Commit and push to the fork**

```bash
git add -A
git commit -m "feat(config): make automatic quote substitution configurable

Adds SpellCheckingPolicy.automaticQuoteSubstitution (default true — behavior
unchanged for existing embedders). Markdown-source embedders can now keep
straight quotes; previously isAutomaticQuoteSubstitutionEnabled was hard-coded
on in NativeTextViewWrapper and the autocorrect suppress-zone restore path."
git push anglesite anglesite-pin
git rev-parse HEAD   # record this as FORK-SHA for Task 2
```

Expected: push succeeds; note the SHA.

---

### Task 2: Add the dependency to Package.swift + project.yml

**Files:**
- Modify: `Package.swift` (inside the existing `#if canImport(Darwin)` dependency block after the STTextView-Plugin-Neon append, ~line 333; and the `AnglesiteAppCore` target dependencies, ~line 228)
- Modify: `project.yml` (`packages:` map ~line 11; `Anglesite` target `dependencies:` list where the STTextView package entries are, ~line 96)

**Interfaces:**
- Consumes: **FORK-SHA** from Task 1.
- Produces: `import MarkdownEngine` available to `Sources/AnglesiteApp` in both the SwiftPM target (`AnglesiteAppCore`) and the Xcode app target.

- [ ] **Step 2.1: Package.swift — package dependency**

Append inside the `#if canImport(Darwin)` block (after the STTextView-Plugin-Neon append):

```swift
// Markdown editor substrate (#797; survey #796 — see the spec addendum in
// docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md). Anglesite's
// fork of nodes-app/swift-markdown-engine v0.10.0 plus one patch making automatic quote
// substitution configurable (SpellCheckingPolicy.automaticQuoteSubstitution) — smart quotes
// corrupt Markdown sources. Only the zero-dependency core `MarkdownEngine` product is linked
// (no MarkdownEngineCodeBlocks/MarkdownEngineLatex — LaTeX and highlighted fences are out of
// scope for v1, §A.2). Pinned by revision, matching the SwiftGit2/STTextView policy above:
// deliberate bumps only (upstream is pre-1.0 and its API moves).
packageDependencies.append(
    .package(url: "https://github.com/Anglesite/swift-markdown-engine", revision: "FORK-SHA")
)
```

(Replace `FORK-SHA` with the SHA recorded in Step 1.6.)

- [ ] **Step 2.2: Package.swift — AnglesiteAppCore product**

In the `AnglesiteAppCore` target's dependencies (next to the STTextView products):

```swift
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
```

- [ ] **Step 2.3: project.yml — package + target dependency**

In `packages:`:

```yaml
  # Markdown editor substrate (#797): Anglesite's patched fork of
  # nodes-app/swift-markdown-engine, pinned by revision — see the matching
  # Package.swift comment for the full rationale.
  MarkdownEngine:
    url: https://github.com/Anglesite/swift-markdown-engine
    revision: FORK-SHA
```

In the `Anglesite` target's `dependencies:` (next to the STTextView entries):

```yaml
      - package: MarkdownEngine
        product: MarkdownEngine
```

- [ ] **Step 2.4: Regenerate and build**

```bash
xcodegen generate
swift build --target AnglesiteAppCore
```

Expected: resolves `swift-markdown-engine` at the pinned revision; builds with no errors.

- [ ] **Step 2.5: Commit**

```bash
git add Package.swift project.yml
git commit -m "feat(editor): add swift-markdown-engine substrate dependency (#797)

Anglesite fork of nodes-app/swift-markdown-engine v0.10.0 + smart-quote
config patch, pinned by revision per the #796 survey addendum."
```

---

### Task 3: `EditorKind.markdown` routing case

**Files:**
- Modify: `Sources/AnglesiteCore/EditorKind.swift`
- Modify: `Sources/AnglesiteApp/MainPaneEditorView.swift:35` (temporary exhaustiveness only)
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:793` (`openFile` switch)
- Test: `Tests/AnglesiteCoreTests/EditorKindTests.swift`

**Interfaces:**
- Produces: `EditorKind.markdown`, resolved for `md`/`mdx`/`markdown` extensions in every `FileGroup`. Task 7 replaces the temporary `MainPaneEditorView` arm with the real editor.

- [ ] **Step 3.1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/EditorKindTests.swift` (Swift Testing, matches existing fixtures):

```swift
    @Test("markdown files route to the markdown editor in every group")
    func markdownFilesUseMarkdownEditor() {
        for ext in ["md", "mdx", "markdown", "MD"] {
            for group in FileGroup.allCases {
                let ref = FileRef(url: URL(fileURLWithPath: "/tmp/post.\(ext)"), group: group, name: "post.\(ext)")
                #expect(EditorKind.resolve(for: ref) == .markdown)
            }
        }
    }

    @Test("markdown-adjacent extensions stay text")
    func markdownLookalikesStayText() {
        for name in ["notes.mdoc", "readme.txt", "md"] {
            let ref = FileRef(url: URL(fileURLWithPath: "/tmp/\(name)"), group: .pages, name: name)
            #expect(EditorKind.resolve(for: ref) == .text)
        }
    }
```

(If `FileGroup` has no `.pages` case, use any case from `FileGroup.allCases` — mirror the existing tests in the same file.)

- [ ] **Step 3.2: Run to verify failure**

```bash
swift test --package-path . --filter EditorKindTests
```

Expected: FAIL — `type 'EditorKind' has no member 'markdown'` (compile error counts).

- [ ] **Step 3.3: Implement**

`Sources/AnglesiteCore/EditorKind.swift`:

```swift
public enum EditorKind: Sendable, Equatable {
    case text
    case plist
    case component
    case markdown

    /// Resolves the editor for a file. A single decision point so the routing rule lives in one
    /// tested place; kept on the enum to keep the public API surface tidy.
    public static func resolve(for file: FileRef) -> EditorKind {
        if file.group == .metadata, file.url.pathExtension.lowercased() == "plist" {
            return .plist
        }
        if file.group == .components, file.url.pathExtension.lowercased() == "astro" {
            return .component
        }
        if ["md", "mdx", "markdown"].contains(file.url.pathExtension.lowercased()) {
            return .markdown
        }
        return .text
    }
}
```

Keep the app target compiling (both switches are exhaustive):

`Sources/AnglesiteApp/MainPaneEditorView.swift:35` — temporarily widen the text arm (Task 7 gives `.markdown` its real editor):

```swift
                    case .text, .plist, .markdown:
```

`Sources/AnglesiteApp/SiteWindowModel.swift:793` — markdown files edit through a plain `FileEditorModel`, same as `.text`:

```swift
            case .text, .component, .markdown:
```

- [ ] **Step 3.4: Run tests + build**

```bash
swift test --package-path . --filter EditorKindTests
swift build --target AnglesiteAppCore
```

Expected: tests PASS; build succeeds.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/AnglesiteCore/EditorKind.swift Sources/AnglesiteApp/MainPaneEditorView.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteCoreTests/EditorKindTests.swift
git commit -m "feat(editor): add EditorKind.markdown for md/mdx/markdown files (#797)"
```

---

### Task 4: `MarkdownEditorController` + focus registry

Foundation-only command surface: menus and the find bar call the controller; the controller posts per-instance `NotificationCenter` names; `MarkdownTextView` (Task 5) registers those names as the engine's bus. Names are unique per instance because the engine's coordinator applies bus notifications unconditionally — shared names would format every open editor.

**Files:**
- Create: `Sources/AnglesiteApp/MarkdownEditorController.swift`
- Test: `Tests/AnglesiteAppTests/MarkdownEditorControllerTests.swift`

**Interfaces:**
- Produces (consumed by Tasks 5–8):
  - `MarkdownEditorController` (`@MainActor @Observable final class`): `busNames: BusNames`, `focusEditor: (() -> Void)?`, `perform(_: FormatCommand)`, find state (`isFindBarVisible`, `showsReplace`, `query`, `replacement`, `matchCount`, `currentMatchIndex`) and find actions (`showFind(withReplace:)`, `hideFind()`, `queryChanged()`, `findNext()`, `findPrevious()`, `replaceCurrentMatch()`, `replaceAllMatches()`).
  - `MarkdownEditorController.FormatCommand`: `.bold, .italic, .strikethrough, .inlineCode, .heading(Int), .link`.
  - `MarkdownEditorFocusRegistry` (`@MainActor @Observable`, `static let shared`): `active: MarkdownEditorController?`, `activate(_:)`, `resign(_:)`.

- [ ] **Step 4.1: Write the failing tests**

`Tests/AnglesiteAppTests/MarkdownEditorControllerTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteAppCore

@MainActor
struct MarkdownEditorControllerTests {
    @Test("bus names are unique per controller instance and per verb")
    func busNamesUnique() {
        let a = MarkdownEditorController()
        let b = MarkdownEditorController()
        #expect(a.busNames.applyBold != b.busNames.applyBold)
        #expect(a.busNames.findQuery != b.busNames.findQuery)
        #expect(a.busNames.applyBold != a.busNames.applyItalic)
    }

    @Test("perform posts the matching bus notification")
    func performPostsNotification() async {
        let controller = MarkdownEditorController()
        await confirmation { confirm in
            let token = NotificationCenter.default.addObserver(
                forName: controller.busNames.applyBold, object: nil, queue: nil) { _ in confirm() }
            controller.perform(.bold)
            NotificationCenter.default.removeObserver(token)
        }
    }

    @Test("heading command carries its level")
    func headingCarriesLevel() {
        final class Box: @unchecked Sendable { var level: Int? }   // sync delivery on main
        let controller = MarkdownEditorController()
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: controller.busNames.applyHeading, object: nil, queue: nil) { note in
            box.level = note.userInfo?["level"] as? Int
        }
        controller.perform(.heading(3))
        NotificationCenter.default.removeObserver(token)
        #expect(box.level == 3)
    }

    @Test("find results from the engine update match state, and next/previous wrap")
    func findResultsAndWrapping() {
        let controller = MarkdownEditorController()
        controller.query = "needle"
        NotificationCenter.default.post(
            name: controller.busNames.findResults, object: nil, userInfo: ["count": 3])
        #expect(controller.matchCount == 3)
        controller.findNext()
        controller.findNext()
        controller.findNext()   // 0 → 1 → 2 → wraps to 0
        #expect(controller.currentMatchIndex == 0)
        controller.findPrevious()   // wraps back to 2
        #expect(controller.currentMatchIndex == 2)
    }

    @Test("shrinking results clamp the current index")
    func shrinkingResultsClampIndex() {
        let controller = MarkdownEditorController()
        controller.query = "x"
        NotificationCenter.default.post(
            name: controller.busNames.findResults, object: nil, userInfo: ["count": 5])
        controller.findNext(); controller.findNext(); controller.findNext(); controller.findNext()
        #expect(controller.currentMatchIndex == 4)
        NotificationCenter.default.post(
            name: controller.busNames.findResults, object: nil, userInfo: ["count": 2])
        #expect(controller.currentMatchIndex == 1)
    }

    @Test("registry resign only clears its own controller")
    func registryResignIsOwnershipChecked() {
        let registry = MarkdownEditorFocusRegistry()
        let a = MarkdownEditorController()
        let b = MarkdownEditorController()
        registry.activate(a)
        registry.activate(b)
        registry.resign(a)   // stale resign from a must not clobber b
        #expect(registry.active === b)
        registry.resign(b)
        #expect(registry.active == nil)
    }
}
```

- [ ] **Step 4.2: Run to verify failure**

```bash
swift test --package-path . --filter MarkdownEditorControllerTests
```

Expected: FAIL — `cannot find 'MarkdownEditorController' in scope`.

- [ ] **Step 4.3: Implement**

`Sources/AnglesiteApp/MarkdownEditorController.swift`:

```swift
import Foundation
import Observation

/// App-level command surface for one hosted Markdown editor (#797). Menu commands and the find
/// bar talk to this controller; it forwards to the engine over per-instance NotificationCenter
/// names (`BusNames`) that `MarkdownTextView` registers as the engine's `MarkdownEditorBus`.
/// Foundation-only on purpose: nothing outside MarkdownTextView.swift imports MarkdownEngine
/// (#796 addendum — the substrate stays swappable).
@MainActor @Observable
final class MarkdownEditorController {

    /// Formatting verbs the Format menu sends to the focused editor. Each maps 1:1 onto an
    /// engine bus notification; the engine owns the toggle/wrap semantics (and the undo path).
    enum FormatCommand: Equatable {
        case bold, italic, strikethrough, inlineCode
        case heading(Int)
        case link
    }

    /// Per-instance notification names. Unique per controller because the engine's coordinator
    /// applies a bus notification unconditionally — shared names would format every open editor.
    struct BusNames {
        let applyBold: Notification.Name
        let applyItalic: Notification.Name
        let applyHeading: Notification.Name
        let applyStrikethrough: Notification.Name
        let applyInlineCode: Notification.Name
        let applyLink: Notification.Name
        let findQuery: Notification.Name
        let findClearHighlights: Notification.Name
        let findResults: Notification.Name
        let replaceCurrent: Notification.Name
        let replaceAll: Notification.Name

        init(id: UUID) {
            func make(_ suffix: String) -> Notification.Name {
                Notification.Name("io.dwk.anglesite.markdown-editor.\(id.uuidString).\(suffix)")
            }
            applyBold = make("applyBold")
            applyItalic = make("applyItalic")
            applyHeading = make("applyHeading")
            applyStrikethrough = make("applyStrikethrough")
            applyInlineCode = make("applyInlineCode")
            applyLink = make("applyLink")
            findQuery = make("findQuery")
            findClearHighlights = make("findClearHighlights")
            findResults = make("findResults")
            replaceCurrent = make("replaceCurrent")
            replaceAll = make("replaceAll")
        }
    }

    let busNames: BusNames
    /// Installed by `MarkdownTextView`; returns keyboard focus to the engine text view
    /// (used when the find bar dismisses).
    var focusEditor: (() -> Void)?

    // MARK: Find state (rendered by MarkdownFindBar; highlights drawn by the engine)

    var isFindBarVisible = false
    var showsReplace = false
    var query = ""
    var replacement = ""
    private(set) var matchCount = 0
    private(set) var currentMatchIndex = 0

    private var resultsObserver: (any NSObjectProtocol)?

    init() {
        busNames = BusNames(id: UUID())
        // queue: nil → delivered synchronously on the posting thread. The engine posts results
        // from its own main-queue bus handler, so assumeIsolated holds.
        resultsObserver = NotificationCenter.default.addObserver(
            forName: busNames.findResults, object: nil, queue: nil
        ) { [weak self] note in
            let count = note.userInfo?["count"] as? Int ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                self.matchCount = count
                if self.currentMatchIndex >= count { self.currentMatchIndex = max(0, count - 1) }
            }
        }
    }

    deinit {
        if let resultsObserver { NotificationCenter.default.removeObserver(resultsObserver) }
    }

    // MARK: Formatting

    func perform(_ command: FormatCommand) {
        let center = NotificationCenter.default
        switch command {
        case .bold: center.post(name: busNames.applyBold, object: nil)
        case .italic: center.post(name: busNames.applyItalic, object: nil)
        case .strikethrough: center.post(name: busNames.applyStrikethrough, object: nil)
        case .inlineCode: center.post(name: busNames.applyInlineCode, object: nil)
        case .heading(let level):
            center.post(name: busNames.applyHeading, object: nil, userInfo: ["level": level])
        case .link:
            // Empty URL: the engine wraps the selection as `[selection]()` with the caret in the
            // URL slot, or inserts `[]()` with the caret in the text slot when nothing is selected.
            center.post(name: busNames.applyLink, object: nil, userInfo: ["url": ""])
        }
    }

    // MARK: Find

    func showFind(withReplace: Bool = false) {
        isFindBarVisible = true
        if withReplace { showsReplace = true }
        if !query.isEmpty { runQuery() }
    }

    func hideFind() {
        isFindBarVisible = false
        showsReplace = false
        NotificationCenter.default.post(name: busNames.findClearHighlights, object: nil)
        focusEditor?()
    }

    /// Restarts the search from the first match; the find bar calls this whenever `query` changes.
    func queryChanged() {
        currentMatchIndex = 0
        if query.isEmpty {
            matchCount = 0
            NotificationCenter.default.post(name: busNames.findClearHighlights, object: nil)
        } else {
            runQuery()
        }
    }

    func findNext() {
        guard matchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchCount
        runQuery()
    }

    func findPrevious() {
        guard matchCount > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchCount) % matchCount
        runQuery()
    }

    func replaceCurrentMatch() {
        guard matchCount > 0, !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: busNames.replaceCurrent, object: nil,
            userInfo: ["query": query, "replacement": replacement, "currentIndex": currentMatchIndex])
    }

    func replaceAllMatches() {
        guard !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: busNames.replaceAll, object: nil,
            userInfo: ["query": query, "replacement": replacement])
    }

    private func runQuery() {
        NotificationCenter.default.post(
            name: busNames.findQuery, object: nil,
            userInfo: ["query": query, "currentIndex": currentMatchIndex])
    }
}

/// Which markdown editor currently owns keyboard focus, app-wide. Two editors can share one
/// window (main-pane file editor + inspector body field), so a per-window `focusedSceneValue`
/// can't disambiguate; `MarkdownTextView`'s first-responder sentinel drives this instead.
@MainActor @Observable
final class MarkdownEditorFocusRegistry {
    static let shared = MarkdownEditorFocusRegistry()
    private(set) var active: MarkdownEditorController?

    func activate(_ controller: MarkdownEditorController) {
        if active !== controller { active = controller }
    }

    /// Clears `active` only while `controller` still owns it — a later `activate` from another
    /// editor must not be clobbered by a stale resign.
    func resign(_ controller: MarkdownEditorController) {
        if active === controller { active = nil }
    }
}
```

- [ ] **Step 4.4: Run tests**

```bash
swift test --package-path . --filter MarkdownEditorControllerTests
```

Expected: PASS (6 tests).

- [ ] **Step 4.5: Commit**

```bash
git add Sources/AnglesiteApp/MarkdownEditorController.swift Tests/AnglesiteAppTests/MarkdownEditorControllerTests.swift
git commit -m "feat(editor): MarkdownEditorController command/find seam + focus registry (#797)"
```

---

### Task 5: `MarkdownTextView` — the engine seam

Hosts the engine's `NativeTextViewWrapper` inside an `NSHostingView` wrapped in a first-responder-tracking container. The container is what lets the app know *which* markdown editor owns keyboard focus — the engine view alone offers no seam for that.

**Files:**
- Create: `Sources/AnglesiteApp/MarkdownTextView.swift`

**Interfaces:**
- Consumes: `MarkdownEditorController` / `MarkdownEditorFocusRegistry` (Task 4); `MarkdownEngine` products (Task 2).
- Produces: `MarkdownTextView(text: Binding<String>, controller: MarkdownEditorController, documentId: String, fitsContent: Bool = false)` — consumed by Tasks 6–7.

- [ ] **Step 5.1: Implement**

`Sources/AnglesiteApp/MarkdownTextView.swift`:

```swift
import SwiftUI
import AppKit
import MarkdownEngine

/// SwiftUI seam over swift-markdown-engine's live-styled Markdown editor (#797; spec §A.3,
/// substrate decided by the #796 survey addendum). The ONLY file in the app that imports
/// MarkdownEngine — call sites (editor routing, menu commands, find bar) speak
/// `MarkdownEditorController`, so the substrate stays swappable.
struct MarkdownTextView: View {
    @Binding var text: String
    let controller: MarkdownEditorController
    var documentId: String
    /// `true` for form embedding (typed-entry body): the editor grows to fit and the enclosing
    /// Form scrolls. `false` (default) scrolls internally — the main-pane file editor.
    var fitsContent = false

    var body: some View {
        EngineHost(text: $text, controller: controller, documentId: documentId, fitsContent: fitsContent)
    }
}

/// Bridges the engine's own `NSViewRepresentable` through an `NSHostingView` inside a
/// first-responder-tracking container so `MarkdownEditorFocusRegistry` always knows which
/// editor is focused (two can share a window: main pane + inspector).
private struct EngineHost: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var documentId: String
    var fitsContent: Bool

    func makeNSView(context: Context) -> FocusTrackingContainerView {
        let container = FocusTrackingContainerView(hosting: NSHostingView(rootView: engineView))
        container.onFocusChange = { [weak controller] focused in
            guard let controller else { return }
            if focused {
                MarkdownEditorFocusRegistry.shared.activate(controller)
            } else {
                MarkdownEditorFocusRegistry.shared.resign(controller)
            }
        }
        controller.focusEditor = { [weak container] in
            container?.focusTextView()
        }
        return container
    }

    func updateNSView(_ nsView: FocusTrackingContainerView, context: Context) {
        nsView.hostingView.rootView = engineView
    }

    static func dismantleNSView(_ nsView: FocusTrackingContainerView, coordinator: ()) {
        nsView.prepareForRemoval()
    }

    private var engineView: NativeTextViewWrapper {
        NativeTextViewWrapper(
            text: $text,
            configuration: Self.configuration(for: controller, fitsContent: fitsContent),
            documentId: documentId
        )
    }

    private static func configuration(
        for controller: MarkdownEditorController, fitsContent: Bool
    ) -> MarkdownEditorConfiguration {
        let names = controller.busNames
        let bus = MarkdownEditorBus(
            applyBoldRequest: names.applyBold,
            applyItalicRequest: names.applyItalic,
            applyHeadingRequest: names.applyHeading,
            applyStrikethroughRequest: names.applyStrikethrough,
            applyInlineCodeRequest: names.applyInlineCode,
            applyLinkRequest: names.applyLink,
            findClearHighlights: names.findClearHighlights,
            findQuery: names.findQuery,
            findResults: names.findResults,
            replaceCurrent: names.replaceCurrent,
            replaceAll: names.replaceAll
        )
        return MarkdownEditorConfiguration(
            services: MarkdownEditorServices(bus: bus),
            // Fork-added toggle (Anglesite/swift-markdown-engine): Markdown sources need straight
            // quotes — smart quotes would corrupt frontmatter and code samples (addendum §2).
            spellChecking: SpellCheckingPolicy(automaticQuoteSubstitution: false),
            heightBehavior: fitsContent ? .fitsContent : .scrolls,
            // GFM strikethrough is in the v1 construct set (spec §A.2); it's an opt-in
            // engine extension.
            extensions: [StrikethroughExtension()]
        )
    }
}

/// Container that hosts the engine's view hierarchy and reports whether the window's first
/// responder lives inside it. Field-editor responders (find bar / inspector text fields) are
/// attributed to their owning control, so focus in a text field correctly reads as "outside".
final class FocusTrackingContainerView: NSView {
    let hostingView: NSHostingView<NativeTextViewWrapper>
    var onFocusChange: ((Bool) -> Void)?
    private var observation: NSKeyValueObservation?
    private var isFocused = false

    init(hosting: NSHostingView<NativeTextViewWrapper>) {
        self.hostingView = hosting
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.invalidate()
        observation = nil
        guard let window else {
            update(focused: false)
            return
        }
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            // NSWindow mutates firstResponder on the main thread; the hop is for the compiler.
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
    }

    /// Restores keyboard focus to the engine's text view (find-bar dismissal).
    func focusTextView() {
        if let textView = Self.firstDescendantTextView(of: self) {
            window?.makeFirstResponder(textView)
        }
    }

    func prepareForRemoval() {
        update(focused: false)
        onFocusChange = nil
        observation?.invalidate()
        observation = nil
    }

    private func refreshFocus() {
        guard let window else {
            update(focused: false)
            return
        }
        var responderView = window.firstResponder as? NSView
        if let text = window.firstResponder as? NSText, text.isFieldEditor {
            responderView = text.delegate as? NSView
        }
        update(focused: responderView?.isDescendant(of: self) ?? false)
    }

    private func update(focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        onFocusChange?(focused)
    }

    private static func firstDescendantTextView(of view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let textView = sub as? NSTextView { return textView }
            if let found = firstDescendantTextView(of: sub) { return found }
        }
        return nil
    }
}
```

Notes for the implementer:
- If `StrikethroughExtension()` has a different initializer, check `Sources/MarkdownEngine/Extensions/StrikethroughExtension.swift` in the pinned checkout (`.build/checkouts/swift-markdown-engine/`) and adjust.
- `MarkdownEditorBus` init parameters all default to `nil`; only the ones above are passed — the unused verbs (blockquote, lists, code block, HR, image, wiki-link/selection notifications) stay disabled.

- [ ] **Step 5.2: Build**

```bash
swift build --target AnglesiteAppCore
```

Expected: builds clean (strict concurrency on — `MainActor.assumeIsolated` covers the KVO/notification hops).

- [ ] **Step 5.3: Commit**

```bash
git add Sources/AnglesiteApp/MarkdownTextView.swift
git commit -m "feat(editor): MarkdownTextView seam hosting swift-markdown-engine (#797)"
```

---

### Task 6: Find bar

**Files:**
- Create: `Sources/AnglesiteApp/MarkdownFindBar.swift`
- Modify: `Sources/AnglesiteApp/MarkdownTextView.swift` (show the bar above the editor)

**Interfaces:**
- Consumes: `MarkdownEditorController` find state/actions (Task 4).
- Produces: `MarkdownFindBar(controller:)`; `MarkdownTextView` now renders it when `controller.isFindBarVisible`.

- [ ] **Step 6.1: Implement the bar**

`Sources/AnglesiteApp/MarkdownFindBar.swift`:

```swift
import SwiftUI

/// Find / replace bar shown above a `MarkdownTextView` (#517 Edit ▸ Find). Pure chrome: match
/// highlighting, navigation, and replacement all execute inside the engine via the controller's
/// bus; this view renders state and forwards intents.
struct MarkdownFindBar: View {
    @Bindable var controller: MarkdownEditorController
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Find", text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFieldFocused)
                    .frame(maxWidth: 320)
                    .onSubmit { controller.findNext() }
                Text(matchCountLabel)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                ControlGroup {
                    Button { controller.findPrevious() } label: { Image(systemName: "chevron.left") }
                        .help("Find Previous")
                    Button { controller.findNext() } label: { Image(systemName: "chevron.right") }
                        .help("Find Next")
                }
                .disabled(controller.matchCount == 0)
                .frame(width: 72)
                Spacer()
                Toggle("Replace", isOn: $controller.showsReplace)
                    .toggleStyle(.checkbox)
                Button("Done") { controller.hideFind() }
            }
            if controller.showsReplace {
                HStack(spacing: 8) {
                    TextField("Replace With", text: $controller.replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Button("Replace") { controller.replaceCurrentMatch() }
                        .disabled(controller.matchCount == 0)
                    Button("Replace All") { controller.replaceAllMatches() }
                        .disabled(controller.matchCount == 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { findFieldFocused = true }
        // The find bar sits OUTSIDE the engine's focus-tracking container, so gaining field focus
        // would otherwise read as "editor lost focus" and disable Find Next/Format mid-search.
        .onChange(of: findFieldFocused) { _, focused in
            if focused { MarkdownEditorFocusRegistry.shared.activate(controller) }
        }
        .onChange(of: controller.query) { controller.queryChanged() }
        .onExitCommand { controller.hideFind() }
    }

    private var matchCountLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return String(localized: "No matches") }
        return String(localized: "\(controller.currentMatchIndex + 1) of \(controller.matchCount)")
    }
}
```

- [ ] **Step 6.2: Show it in `MarkdownTextView`**

Replace `MarkdownTextView.body`:

```swift
    var body: some View {
        VStack(spacing: 0) {
            if controller.isFindBarVisible {
                MarkdownFindBar(controller: controller)
                Divider()
            }
            EngineHost(text: $text, controller: controller, documentId: documentId, fitsContent: fitsContent)
        }
    }
```

- [ ] **Step 6.3: Build + commit**

```bash
swift build --target AnglesiteAppCore
git add Sources/AnglesiteApp/MarkdownFindBar.swift Sources/AnglesiteApp/MarkdownTextView.swift
git commit -m "feat(editor): in-editor find/replace bar over the engine bus (#797, #517)"
```

---

### Task 7: Route the editors

**Files:**
- Modify: `Sources/AnglesiteApp/MainPaneEditorView.swift` (split `.markdown` out of the temporary arm)
- Modify: `Sources/AnglesiteApp/FileEditorModel.swift` (add controller property)
- Modify: `Sources/AnglesiteApp/TypedEntryEditorView.swift:16-22` (body field swap)
- Modify: `Sources/AnglesiteApp/TypedEntryEditorModel.swift` (add controller property)

**Interfaces:**
- Consumes: `MarkdownTextView` (Tasks 5–6), `EditorKind.markdown` (Task 3).
- Produces: `FileEditorModel.markdownController` / `TypedEntryEditorModel.markdownController` (both `let`, type `MarkdownEditorController`).

- [ ] **Step 7.1: `FileEditorModel` + main pane**

Add to `FileEditorModel` (next to its other stored properties):

```swift
    /// Command/find seam for the markdown editor surface; unused for other editor kinds.
    let markdownController = MarkdownEditorController()
```

In `MainPaneEditorView.swift`, restore the original text arm and give `.markdown` its editor:

```swift
                    switch EditorKind.resolve(for: model.file) {
                    case .text, .plist:
                        TextEditor(text: $model.text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    case .markdown:
                        MarkdownTextView(
                            text: $model.text,
                            controller: model.markdownController,
                            documentId: model.file.id
                        )
                    case .component:
```

(`FileEditorModel` is `@MainActor`; if the controller property triggers an isolation error at the `let` initializer, initialize it inside the existing `init` instead.)

- [ ] **Step 7.2: Typed-entry body field**

Add to `TypedEntryEditorModel` (next to `let file: FileRef`):

```swift
    /// Command/find seam for the body field's markdown editor.
    let markdownController = MarkdownEditorController()
```

In `TypedEntryEditorView.swift`, replace the Body section's `TextEditor`:

```swift
            if let body = bodyField {
                Section("Body") {
                    MarkdownTextView(
                        text: model.textBinding(body.name),
                        controller: model.markdownController,
                        // Distinct from the main-pane editor of the same file (different text
                        // scope — body-only vs whole file), so their undo stacks never mix.
                        documentId: model.file.id + "#body",
                        fitsContent: true
                    )
                    .frame(minHeight: 160)
                }
            }
```

- [ ] **Step 7.3: Build the app target (regenerates the String Catalog)**

```bash
swift build --target AnglesiteAppCore
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
git status --short Sources/AnglesiteApp/Localizable.xcstrings
```

Expected: both build; review the `.xcstrings` diff (new find-bar strings: "Find", "Replace", "Replace With", "Replace All", "Done", "No matches", "%lld of %lld", "Find Previous", "Find Next").

- [ ] **Step 7.4: Run the app-adjacent suites**

```bash
swift test --package-path . --filter "EditorKindTests|MarkdownEditorControllerTests"
```

Expected: PASS.

- [ ] **Step 7.5: Commit (include the String Catalog)**

```bash
git add Sources/AnglesiteApp/MainPaneEditorView.swift Sources/AnglesiteApp/FileEditorModel.swift Sources/AnglesiteApp/TypedEntryEditorView.swift Sources/AnglesiteApp/TypedEntryEditorModel.swift Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(editor): route .md/.mdx files and typed-entry bodies to MarkdownTextView (#797)"
```

---

### Task 8: Live Format menu + Edit ▸ Find menu

**Files:**
- Modify: `Sources/AnglesiteApp/FormatCommands.swift`
- Modify: `Sources/AnglesiteApp/EditMenuSkeletonCommands.swift`

**Interfaces:**
- Consumes: `MarkdownEditorFocusRegistry.shared.active`, `MarkdownEditorController.perform(_:)` / find actions.

- [ ] **Step 8.1: Check heading-shortcut conflicts**

```bash
grep -rn "modifiers: \[.command, .option\]" Sources/AnglesiteApp --include="*.swift" | grep -E '"[1-6]"'
```

Expected: no hits (⌥⌘1–⌥⌘6 free). If a conflict appears, drop the heading shortcuts (menu items only) and note it in the PR.

- [ ] **Step 8.2: Rewrite `FormatCommands.swift`**

Make live: Strong ⌘B, Emphasis ⌘I, Strikethrough, Code, Heading 1–6 (⌥⌘1–6), Add Link… ⌘K. Everything else stays a `PlannedItem` (untouched). The full new file:

```swift
import SwiftUI

/// The Format menu (menu-bar spec §2.6). Font items are semantic elements (strong/em/u/s/code),
/// not visual styling. The Markdown items are live against the focused Markdown editor
/// (#797/#517) via `MarkdownEditorFocusRegistry` — a focused-value can't disambiguate two
/// editors in one window (main pane + inspector), so the registry is the deliberate departure
/// from the PlannedItem→focused-value convention. Remaining items stay PlannedItems until
/// their editors land (the Component Editor #496 owns the non-Markdown surfaces).
struct FormatCommands: Commands {
    private let registry = MarkdownEditorFocusRegistry.shared

    var body: some Commands {
        CommandMenu("Format") {
            Menu("Font") {
                Button("Strong") { registry.active?.perform(.bold) }
                    .keyboardShortcut("b")
                    .disabled(registry.active == nil)
                Button("Emphasis") { registry.active?.perform(.italic) }
                    .keyboardShortcut("i")
                    .disabled(registry.active == nil)
                PlannedItem("Underline", shortcut: "u")
                Button("Strikethrough") { registry.active?.perform(.strikethrough) }
                    .disabled(registry.active == nil)
                Button("Code") { registry.active?.perform(.inlineCode) }
                    .disabled(registry.active == nil)
            }

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { registry.active?.perform(.heading(level)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                        .disabled(registry.active == nil)
                }
            }

            Menu("Text") {
                PlannedItem("Align Left", shortcut: "{")
                PlannedItem("Align Center", shortcut: "|")
                PlannedItem("Align Right", shortcut: "}")
                PlannedItem("Justify")
                PlannedItem("Auto-Align Table Cell")

                Divider()

                PlannedItem("Increase Indent Level", shortcut: "]")
                PlannedItem("Decrease Indent Level", shortcut: "[")

                Divider()

                PlannedItem("Reverse Text Direction")
            }

            PlannedItem("Table")
            PlannedItem("Image")

            Divider()

            PlannedItem("Copy Style", shortcut: "c", modifiers: [.command, .option])
            PlannedItem("Paste Style", shortcut: "v", modifiers: [.command, .option])
            PlannedItem("Copy Animation")
            PlannedItem("Paste Animation")

            Divider()

            Button("Add Link…") { registry.active?.perform(.link) }
                .keyboardShortcut("k")
                .disabled(registry.active == nil)
            PlannedItem("Remove Link")
        }
    }
}
```

- [ ] **Step 8.3: Live Find items in `EditMenuSkeletonCommands.swift`**

Replace the `Menu("Find")` block:

```swift
            Menu("Find") {
                Button("Find…") { registry.active?.showFind() }
                    .keyboardShortcut("f")
                    .disabled(registry.active == nil)
                Button("Find Next") { registry.active?.findNext() }
                    .keyboardShortcut("g")
                    .disabled(registry.active == nil)
                Button("Find Previous") { registry.active?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(registry.active == nil)
                Button("Find & Replace…") { registry.active?.showFind(withReplace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(registry.active == nil)
                PlannedItem("Use Selection for Find", shortcut: "e")

                Divider()

                // Shares the #520 site-search backend when it lands.
                PlannedItem("Search Site…")
            }
```

and add the registry property to the struct:

```swift
struct EditMenuSkeletonCommands: Commands {
    private let registry = MarkdownEditorFocusRegistry.shared
```

(Update the file's header comment: Find items are now live against the focused Markdown editor.)

- [ ] **Step 8.4: Build (String Catalog regeneration) and test**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
swift test --package-path . --filter "MarkdownEditorControllerTests"
git status --short Sources/AnglesiteApp/Localizable.xcstrings
```

Expected: builds; tests PASS; review/stage the catalog diff (new menu strings: "Heading", "Heading %lld", "Find & Replace…" etc. — note "Strong"/"Emphasis" etc. already exist from the PlannedItems).

- [ ] **Step 8.5: Commit**

```bash
git add Sources/AnglesiteApp/FormatCommands.swift Sources/AnglesiteApp/EditMenuSkeletonCommands.swift Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(menus): live Format (bold/italic/link/headings) + Edit>Find for markdown editors (#797, #517)"
```

---

### Task 9: Full-suite verification

- [ ] **Step 9.1: Full Swift package tests**

```bash
swift test --package-path .
```

Expected: PASS. (MCP/apply-edit e2e suites skip cleanly without `ANGLESITE_PLUGIN_PATH`; `AnglesiteContainerLocalTests` skip without `ANGLESITE_CONTAINER_TESTS=1`. `AstroDevServerTests` port/ready-URL failures are a known flake — re-run before debugging.)

- [ ] **Step 9.2: App target build (clean)**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: BUILD SUCCEEDED; `git status` shows no unexpected generated-file diffs.

- [ ] **Step 9.3: Fix anything that surfaced, then commit if needed**

Any fix lands as its own conventional commit referencing #797.

---

### Task 10: GUI verification (addendum §5 checklist)

Run the built app against the throwaway `~/Sites/smoke` site (create/refresh it via the app's New Site flow if absent). Gotchas from prior sessions: kill stray running Anglesite instances first (`pkill -x Anglesite`), and capture the correct display when screenshotting.

- [ ] **Step 10.1:** Open a blog post `.md` in the main pane. Verify: headings sized, `**bold**` bold with dimmed markers, fenced code monospaced, list hanging indents, blockquote styled — and the raw markers still visible (attribute-only styling).
- [ ] **Step 10.2:** Click a task checkbox — the source flips `[ ]`↔`[x]` (1-char edit), the dirty dot appears, ⌘Z undoes it.
- [ ] **Step 10.3:** ⌘B/⌘I on a selection; Heading 2 via Format ▸ Heading; ⌘K wraps a link. Verify menu items disable when a non-markdown file (e.g. `.css`) is focused.
- [ ] **Step 10.4:** ⌘F → type a word → matches highlight with "n of m"; ⌘G / ⇧⌘G cycle; replace one + all; Esc dismisses and returns focus to the editor.
- [ ] **Step 10.5:** Type `"quotes" and 'apostrophes'` — straight quotes must survive (the fork patch).
- [ ] **Step 10.6:** Byte identity: open a post, scroll, close WITHOUT editing → `git -C ~/Sites/smoke/<site>/Source status` stays clean.
- [ ] **Step 10.7:** Typed entry (inspector): body field shows the styled editor, grows with content, saves through the unchanged model path.
- [ ] **Step 10.8 (addendum §5, manual feel checks):** paste a ~100 KB document and type — no visible latency; Writing Tools appear in the context menu (rewrite round-trip keeps Markdown intact — needs Apple Intelligence enabled; record "not testable on this machine" if unavailable); checkbox hit-target comfortable.
- [ ] **Step 10.9:** Record every outcome (incl. screenshots) for the PR test plan; anything failing goes back through superpowers:systematic-debugging before proceeding.

---

### Task 11: Spec addendum note, push, PR

**Files:**
- Modify: `docs/superpowers/specs/2026-07-17-blog-markdown-editor-publishing-design.md` (addendum §5)

- [ ] **Step 11.1:** Append the on-device verification outcomes to the addendum's item 5 (one short paragraph: date, machine, results of the four checks — this closes the loop the survey explicitly left open).
- [ ] **Step 11.2:** Commit: `docs(specs): record #797 on-device verification outcomes (addendum §5)`.
- [ ] **Step 11.3:** Push the branch; open a PR to `main` using `.github/PULL_REQUEST_TEMPLATE.md` (paired-PR check: **none needed** — no MCP schema change; the engine fork is a build-time dependency, not the sidecar). Body covers: substrate adoption per #796, the fork+patch rationale, the focus-registry departure from the focused-value convention, test plan from Task 10, and `Closes #797` / progress on #517 (Find + most of Format; Use Selection for Find and Format leftovers remain).
- [ ] **Step 11.4:** Remove the issue claim: `gh issue edit 797 --remove-label "🛠️ In Progress"`.

---

## Self-review notes

- **Spec coverage:** issue checkboxes → Task 5/6 (`MarkdownTextView`), Task 3+7 (`EditorKind.markdown` + routing + body swap), engine (v1 constructs §A.2 — headings/bold/italic/strikethrough via extension/code/links/lists/checkboxes/blockquotes all engine-native), Task 8 (Format menu + Find, #517), Task 7 constraint (no save-path change), Tasks 4/9/10 (tests). Addendum §2 config (smart quotes off, plain-Markdown — wiki-link transform is identity without `[[…]]` and we pass no resolver) → Tasks 1/5. Addendum §5 on-device checks → Task 10.8, recorded in Task 11.
- **Spec §Testing deltas (deliberate):** styler golden tests / incremental-restyle equivalence belong to the in-house `AnglesiteMarkdown`, which the addendum explicitly does **not** build — the engine's upstream test suite covers its parser/styler (run in Task 1.5). Byte-identity round-trip is verified end-to-end in Task 10.6 (headless `NSViewRepresentable` instantiation isn't possible in `swift test`).
- **Known accepted behaviors:** YAML frontmatter in whole-file editing renders through markdown styling (`---` as rule); harmless, revisit if noisy. `Commands` bodies reading the `@Observable` registry are expected to re-evaluate on change — if enablement lags in Task 10.3, fall back to always-enabled buttons that no-op on `nil` active (behaviorally identical) and note it.
